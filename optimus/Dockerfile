# optimus/Dockerfile — image for the llama-optimus service (compose.yaml,
# "benchmark" profile only). Builds a sandbox that runs a pinned commit of
# github.com/BrunoArsioli/llama-optimus to work out optimal llama.cpp
# params for a given GGUF model, without installing git, pip, or the tool
# itself on the host.
#
# Multi-stage: git and its transitive deps are only needed to fetch the
# pinned commit, so they're confined to the "builder" stage and don't end
# up in the final image.
#
# The final stage also copies llama-bench straight out of the ramalama
# image (COPY --from=<image>, a build-time step) so this container has a
# byte-identical benchmark binary to the one ramalama actually serves
# with, with nothing mounted or proxied at runtime.
#
FROM localhost/my-ramalama-asahi:latest AS base

RUN dnf install -y --nodocs \
        git ca-certificates python3 python3-pip \
    && dnf clean all \
    && rm -rf /var/cache/dnf

ARG OPTIMUS_COMMIT=11ad87198e5cceb86d9fc0128960da7a24b0e89f
RUN git clone https://github.com/BrunoArsioli/llama-optimus.git /opt/llama-optimus \
 && cd /opt/llama-optimus \
 && git checkout "${OPTIMUS_COMMIT}" \
 && rm -rf .git

WORKDIR /opt/llama-optimus
RUN pip install --no-cache-dir -r requirements.txt \
 && pip install --no-cache-dir .

# LLAMA_BIN and MODEL_PATH are supplied at runtime in compose.yaml
ENTRYPOINT ["python3", "optimus.py"]
