#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: push-openshift-image.sh <source-image> <namespace> <image-name>

Log into the OpenShift image registry route, push the source image, and print
the internal cluster pullspec (image-registry.openshift-image-registry.svc:5000/...).

Environment:
  OCP_REGISTRY_HOST           External registry hostname (skips route discovery)
  OCP_REGISTRY_ROUTE_NAME     Route name (default: auto-discover)
  OCP_REGISTRY_ROUTE_NAMESPACE Registry namespace (default: openshift-image-registry)
  OCP_INTERNAL_REGISTRY_HOST  In-cluster pull host (default: image-registry...svc:5000)
  CONTAINER_TOOL              podman or docker (default: podman, then docker)
  INSECURE_REGISTRY           Set to true for self-signed registry TLS
EOF
}

source_image="${1:-}"
namespace="${2:-}"
image_name="${3:-}"

route_namespace="${OCP_REGISTRY_ROUTE_NAMESPACE:-openshift-image-registry}"
internal_registry_host="${OCP_INTERNAL_REGISTRY_HOST:-image-registry.openshift-image-registry.svc:5000}"
container_tool="${CONTAINER_TOOL:-}"

if [[ -z "${source_image}" || -z "${namespace}" || -z "${image_name}" ]]; then
    usage
    exit 1
fi

if [[ -z "${container_tool}" ]]; then
    if command -v podman >/dev/null 2>&1; then
        container_tool=podman
    elif command -v docker >/dev/null 2>&1; then
        container_tool=docker
    else
        echo "podman or docker is required (set CONTAINER_TOOL)" >&2
        exit 1
    fi
fi

container_tool_name="$(basename "${container_tool}")"
if [[ "${container_tool_name}" == "docker" && "${INSECURE_REGISTRY:-false}" == "true" ]]; then
    echo "INSECURE_REGISTRY=true is unsupported with Docker; configure the Docker daemon for the registry or use Podman" >&2
    exit 1
fi

discover_external_registry_host() {
    if [[ -n "${OCP_REGISTRY_HOST:-}" ]]; then
        printf '%s\n' "${OCP_REGISTRY_HOST}"
        return 0
    fi

    if ! command -v oc >/dev/null 2>&1; then
        return 1
    fi

    local host="" route=""
    if [[ -n "${OCP_REGISTRY_ROUTE_NAME:-}" ]]; then
        host="$(oc get route "${OCP_REGISTRY_ROUTE_NAME}" -n "${route_namespace}" \
            -o jsonpath='{.spec.host}' 2>/dev/null || true)"
        if [[ -n "${host}" ]]; then
            printf '%s\n' "${host}"
            return 0
        fi
    fi

    for route in default-route image-registry; do
        host="$(oc get route "${route}" -n "${route_namespace}" \
            -o jsonpath='{.spec.host}' 2>/dev/null || true)"
        if [[ -n "${host}" ]]; then
            printf '%s\n' "${host}"
            return 0
        fi
    done

    host="$(oc get routes -n "${route_namespace}" \
        -o jsonpath='{.items[?(@.spec.host)].spec.host}' 2>/dev/null | awk '{print $1}')"
    if [[ -n "${host}" ]]; then
        printf '%s\n' "${host}"
        return 0
    fi

    # oc 4.14+ may expose registry info
    host="$(oc registry info 2>/dev/null | awk '/hostname/ {print $NF; exit}')"
    if [[ -n "${host}" ]]; then
        printf '%s\n' "${host}"
        return 0
    fi

    return 1
}

external_host="$(discover_external_registry_host || true)"
if [[ -z "${external_host}" ]]; then
    echo "Could not discover OpenShift image registry external hostname." >&2
    echo "Tried routes in ${route_namespace} (default-route, image-registry, any route)." >&2
    echo "" >&2
    echo "Workarounds:" >&2
    echo "  1) Set OCP_REGISTRY_HOST=<registry-host> $0 ..." >&2
    echo "  2) Push to a registry the cluster can pull and run:" >&2
    echo "       make deploy-external-img IMG=<your-image> SKIP_HELM_CRDS=1" >&2
    echo "  3) Ask cluster admin to expose the image registry route." >&2
    exit 1
fi

echo "Using registry host: ${external_host}" >&2

if [[ -z "$(kubectl get namespace "${namespace}" -o name --ignore-not-found 2>/dev/null)" ]]; then
    echo "Ensuring namespace ${namespace} exists" >&2
    kubectl create namespace "${namespace}" >/dev/null
fi

ocp_tag="$(uuidgen | tr '[:upper:]' '[:lower:]')"
external_image="${external_host}/${namespace}/${image_name}:${ocp_tag}"
internal_image="${internal_registry_host}/${namespace}/${image_name}:${ocp_tag}"

insecure_flag=""
tls_verify="true"
if [[ "${INSECURE_REGISTRY:-false}" == "true" ]]; then
    insecure_flag="--insecure=true"
    tls_verify="false"
fi

echo "Logging into ${external_host}" >&2
if command -v oc >/dev/null 2>&1; then
    oc registry login ${insecure_flag} --registry "${external_host}" >/dev/null
else
    echo "oc is required for registry login" >&2
    exit 1
fi

echo "Tagging ${source_image} as ${external_image}" >&2
"${container_tool}" tag "${source_image}" "${external_image}"

echo "Pushing ${external_image}" >&2
if [[ "${container_tool_name}" == "podman" ]]; then
    "${container_tool}" push "${external_image}" --tls-verify="${tls_verify}" >/dev/null
else
    "${container_tool}" push "${external_image}" >/dev/null
fi

printf '%s\n' "${internal_image}"
