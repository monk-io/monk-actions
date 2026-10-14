#!/bin/sh
# Image building utility script - builds all images from MANIFEST

# Path to the manifest parser. Defaults to the action-bundled location;
# callers may override PARSE_MANIFEST for local testing.
PARSE_MANIFEST="${PARSE_MANIFEST:-/opt/monk-actions/scripts/parse-manifest.sh}"

# Validate MANIFEST exists
if [ ! -f "MANIFEST" ]; then
    echo "Error: MANIFEST file not found"
    exit 1
fi

echo "Building all images from MANIFEST..."

# Get all images from MANIFEST
images=$("$PARSE_MANIFEST" get-images)
if [ -z "$images" ]; then
    echo "No images found in MANIFEST, skipping build"
    exit 0
fi

# Validate registry credentials for pushing
if [ -z "$REGISTRY_ADDRESS" ] || [ -z "$REGISTRY_USERNAME" ] || [ -z "$REGISTRY_PASSWORD" ]; then
    echo "Warning: Missing registry credentials - images will be built but not pushed"
    echo "Required: REGISTRY_ADDRESS, REGISTRY_USERNAME, REGISTRY_PASSWORD"
fi

# Optional shared layer cache (podman only). CACHE_REPO is a repository such as
# ghcr.io/org/project-buildcache; CACHE_USERNAME/CACHE_PASSWORD log in to its
# registry. A failed login disables the cache rather than failing the build.
if [ -n "$CACHE_REPO" ]; then
    if ! command -v podman >/dev/null 2>&1; then
        echo "Warning: layer cache needs podman; building without it"
        CACHE_REPO=""
    elif [ -n "$CACHE_USERNAME" ] && [ -n "$CACHE_PASSWORD" ]; then
        if echo "$CACHE_PASSWORD" | podman login --username "$CACHE_USERNAME" --password-stdin "${CACHE_REPO%%/*}"; then
            echo "Using layer cache $CACHE_REPO"
        else
            echo "Warning: login to ${CACHE_REPO%%/*} failed; building without layer cache"
            CACHE_REPO=""
        fi
    else
        echo "Using layer cache $CACHE_REPO (no login)"
    fi
fi

# Function to build a single image
build_image() {
    local IMAGE_TAG="$1"
    echo "=== Building image: $IMAGE_TAG ==="

    # Get image details from MANIFEST
    IMAGE_DETAILS=$("$PARSE_MANIFEST" get-image-details "$IMAGE_TAG")
    if [ -z "$IMAGE_DETAILS" ]; then
        echo "Error: Could not find image details for $IMAGE_TAG in MANIFEST"
        return 1
    fi

    # Parse the details
    eval "$IMAGE_DETAILS"

    if [ -z "$source" ] || [ -z "$dockerfile" ]; then
        echo "Error: Missing source or dockerfile for image $IMAGE_TAG"
        echo "Source: $source"
        echo "Dockerfile: $dockerfile"
        return 1
    fi

    echo "Building image $tag from source: $source, dockerfile: $dockerfile"

    # Construct full paths
    DOCKERFILE_PATH="$source/$dockerfile"
    BUILD_CONTEXT="$source"

    # Verify files exist
    if [ ! -f "$DOCKERFILE_PATH" ]; then
        echo "Error: Dockerfile not found at $DOCKERFILE_PATH"
        return 1
    fi

    if [ ! -d "$BUILD_CONTEXT" ]; then
        echo "Error: Build context directory not found at $BUILD_CONTEXT"
        return 1
    fi

    echo "Building with:"
    echo "  Tag: $tag"
    echo "  Dockerfile: $DOCKERFILE_PATH"
    echo "  Context: $BUILD_CONTEXT"

    # Build using podman first (better insecure registry support), fallback to docker
    if command -v podman >/dev/null 2>&1; then
        echo "Using podman for build..."
        # With CACHE_REPO set, intermediate layers are pulled from and pushed
        # to that repository, so builds on other runners and branches reuse
        # them (e.g. a project's dependency-build stages).
        if [ -n "$CACHE_REPO" ]; then
            podman build --layers --cache-from "$CACHE_REPO" --cache-to "$CACHE_REPO" \
                -t "$tag" -f "$DOCKERFILE_PATH" "$BUILD_CONTEXT"
        else
            podman build -t "$tag" -f "$DOCKERFILE_PATH" "$BUILD_CONTEXT"
        fi

        # Push to registry if credentials are provided
        if [ -n "$REGISTRY_ADDRESS" ] && [ -n "$REGISTRY_USERNAME" ] && [ -n "$REGISTRY_PASSWORD" ]; then
            echo "Tagging and pushing to registry $REGISTRY_ADDRESS..."
            podman tag "$tag" "$REGISTRY_ADDRESS/$tag"
            if podman push --tls-verify="${REGISTRY_TLS_VERIFY:-true}" --creds="$REGISTRY_USERNAME:$REGISTRY_PASSWORD" "$REGISTRY_ADDRESS/$tag"; then
                echo "Successfully pushed $tag to $REGISTRY_ADDRESS"
            else
                echo "Failed to push image to registry"
                return 1
            fi
        else
            echo "Skipping registry push - missing registry credentials"
        fi
    elif command -v docker >/dev/null 2>&1; then
        echo "Using docker for build (podman not available)..."
        docker build -t "$tag" -f "$DOCKERFILE_PATH" "$BUILD_CONTEXT"

        # Push to registry if credentials are provided
        if [ -n "$REGISTRY_ADDRESS" ] && [ -n "$REGISTRY_USERNAME" ] && [ -n "$REGISTRY_PASSWORD" ]; then
            echo "Logging into registry $REGISTRY_ADDRESS..."

            if echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY_ADDRESS" -u "$REGISTRY_USERNAME" --password-stdin; then
                echo "Successfully logged into registry"

                echo "Tagging and pushing to registry..."
                if docker tag "$tag" "$REGISTRY_ADDRESS/$tag" && docker push "$REGISTRY_ADDRESS/$tag"; then
                    echo "Successfully pushed $tag to $REGISTRY_ADDRESS"
                else
                    echo "Failed to push image to registry"
                    echo "For insecure (HTTP) registries, consider installing podman in your CI/CD environment"
                    docker logout "$REGISTRY_ADDRESS" 2>/dev/null
                    return 1
                fi

                docker logout "$REGISTRY_ADDRESS"
            else
                echo "Failed to login to registry"
                echo "For insecure (HTTP) registries, consider installing podman in your CI/CD environment"
                return 1
            fi
        else
            echo "Skipping registry push - missing registry credentials"
        fi
    else
        echo "Error: Neither podman nor docker found. Please install one of them."
        return 1
    fi

    echo "Successfully built image: $tag"
}

# Build all images
for image in $images; do
    if ! build_image "$image"; then
        echo "Failed to build image: $image"
        exit 1
    fi
    echo ""
done

echo "All images built successfully!"
