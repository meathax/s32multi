# Security and release hygiene

This project does not require credentials at build time and does not store MiSTer
passwords, SSH private keys, API tokens, ROM archives, or other authentication
material. The deployment host is supplied as a command-line argument or the
`S32_MISTER_HOST` environment variable at runtime.

Before publishing a branch or release:

1. Review `git diff --cached` and `git status --short --ignored`.
2. Keep ROMs, Quartus output/database directories, simulator work, and local
   logs out of the commit; the repository `.gitignore` covers the normal cases.
3. Use a short-lived deploy credential or a dedicated MiSTer key outside this
   repository. Never paste it into an MRA, workflow, script, issue, or README.
4. If a credential is ever committed, revoke it immediately and rewrite the
   affected Git history before publishing.

To report a security issue, open a private report with the repository
maintainer rather than posting credential material in a public issue.
