# EOLTrace GitHub Action

Run the native `eoltrace` CLI inside your GitHub Actions runner without uploading source code.

- **Offline by default (`mode: local`)**: scans your repo and writes an inspectable, privacy-validated `eoltrace.scan-manifest/v1` JSON file.
- **Hosted CI (`mode: ci`)**: explicitly submits only the privacy-validated manifest to your EOLTrace server using `EOLTRACE_TOKEN` or GitHub OIDC.
- **Fail-closed**: verifies `SHA256SUMS` before unpacking or running downloaded CLI binaries.

## Quick start

```yaml
- uses: actions/checkout@v4
- id: eoltrace
  uses: sowibrahima/eoltrace-action@main
  with:
    mode: local
    cli-version: cli-v1.1.0
```
