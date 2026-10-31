# Contributing to Session Recovery

## Pull requests are tested before review

Every pull request runs the full CI pipeline automatically. A PR is not ready
for review until its checks are green:

1. **Pester tests** – every PowerShell source must parse cleanly, then
   `tests/SessionRecovery.Tests.ps1` runs against the module in an isolated
   data home.
2. **UI layout audit** – all nine languages are rendered at the minimum window
   size, scrolled to the top and bottom, and every page must report no clipped
   or overlapping controls.
3. **MSI build** – the WiX installer project must build, and the produced MSI
   is uploaded as a CI artifact.
4. **Installer smoke test** – the built MSI is installed, the installed payload
   is compared with the checkout, the installed Studio is rendered, and the
   product is uninstalled with cleanup verified.

Branch protection on `main` treats all four jobs as required: enable
*Settings → Branches → Require status checks to pass* and select
**Pester tests (Windows PowerShell 5.1)**, **UI layout audit (9 languages)**,
**Build MSI**, and **Installer smoke test** once the first CI run has reported.
From then on, no PR can merge without passing tests — the maintainer reviews
only green PRs.

## Adding a feature

- Add or change the logic in `src/SessionRecovery.psm1`.
- Add UI strings for **all nine languages** in `src/Strings.ps1`
  (English is the master table; every key must exist everywhere, and a Pester
  test enforces this).
- Add a Pester test for the new behaviour in `tests/`.
- Run the suite locally:

  ```powershell
  Import-Module Pester -MinimumVersion 5.5 -Force
  Invoke-Pester -Path tests -Output Detailed
  ```

- For UI work, run the layout audit. It renders every page in every language
  at the smallest supported window size:

  ```powershell
  powershell -File tests\Invoke-UiAudit.ps1 -Size 1024x661 -Scroll both
  ```

  Long translated strings (German, Russian, Arabic) are the classic source of
  text overflow bugs. The reports land in a temp folder; pass `-OutputRoot` to
  keep the PNGs and `.check.txt` files for inspection.

## Local verification checklist

- `Invoke-Pester -Path tests` – 90+ tests green.
- `powershell -File tests\Invoke-UiAudit.ps1` – all languages clean.
- `powershell -File src\Restore-Session.ps1 -DryRun` – restore plan prints.
- `powershell -File src\Control-SessionRecovery.ps1 -Command status` – CLI API
  answers.
- `installer\Build-MSI.ps1` – installer builds.
- `tests\Invoke-InstallerSmoke.ps1 -MsiPath .\dist\SessionRecovery-2.8.1.msi` –
  install, payload, render and uninstall all pass.
