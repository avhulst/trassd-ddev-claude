# Pulls the prebuilt Claude Code binary into DDEV's web image.
# DDEV appends this fragment after its own `FROM $BASE_IMAGE`, so a plain
# `COPY --from=<external image>` works — no per-project install, just a fast copy.
#
# Replace OWNER with your GitHub user/org (the GHCR namespace). Pin to a version
# tag (e.g. :2.1.179) for reproducible builds, or use :latest to always track.
COPY --from=ghcr.io/OWNER/claude-code:latest /usr/local/bin/claude /usr/local/bin/claude
