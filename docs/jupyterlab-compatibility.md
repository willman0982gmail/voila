% Copyright (c) 2018, Voilà Contributors
% Copyright (c) 2018, QuantStack
%
% Distributed under the terms of the BSD 3-Clause License.
%
% The full license is in the file LICENSE, distributed with this software.

(jupyterlab-compatibility)=

# JupyterLab Compatibility

This page documents how Voilà relates to JupyterLab versions, with a focus on
**4.4.x**, **4.5.x**, and **4.6.x**. Findings are based on a review of package
constraints, lockfiles, CI configuration, and frontend API usage in this
repository (Voilà 0.5.x).

## Summary

| JupyterLab | Declared by ranges? | Built / locked against? | CI matrix-tested? | Assessment |
| --- | --- | --- | --- | --- |
| **4.4.x** | Yes | No | No | **Intended supported** |
| **4.5.x** | Yes | No | No | **Intended supported** |
| **4.6.x** | Yes | No | No | **Intended supported** |
| 4.2.x (vendored frontend) | Yes | **Yes** (`yarn.lock`) | Indirectly (current `~=4.0`) | Reference build line |
| 5.x | No | No | No | **Not supported** |

**Verdict:** Voilà **declares support for all JupyterLab 4.x releases**, including
4.4.x, 4.5.x, and 4.6.x. JupyterLab itself documents that 4.4–4.6 remain
compatible with extensions that target JupyterLab 4.0. There is **no dedicated
CI matrix** that pins and tests those minor versions, and the shipped Voilà
frontend JavaScript is **locked to the 4.2.5 line**. Treat 4.4–4.6 as
**supported by dependency policy and public API intent**, but **not specifically
proven** in this repository’s automated tests.

## How Voilà uses JupyterLab

Voilà interacts with JupyterLab in two different ways. Compatibility must be
evaluated separately for each.

### 1. Host JupyterLab (preview extension)

`@voila-dashboards/jupyterlab-preview` is a prebuilt JupyterLab extension. It
runs inside the user’s JupyterLab application and uses public extension APIs
(`JupyterFrontEnd`, layout restorer, notebook tracker, main menu, settings,
document registry toolbar buttons).

- Declared `@jupyterlab/*` dependencies use **`^4.0.0`** (any 4.x, including
  4.4–4.6).
- Packaging classifiers include `Framework :: Jupyter :: JupyterLab :: 4`.
- Build and packaging CI install `jupyterlab~=4.0` or `jupyterlab>=4,<5` and
  check that the preview extension is enabled.

For a host JupyterLab of 4.4.x, 4.5.x, or 4.6.x, the preview extension is
**expected to work**, consistent with JupyterLab’s stated extension
compatibility for the 4.x series.

### 2. Standalone Voilà frontend (lab template / tree page)

The Voilà application itself is a JupyterLab-based Module Federation app. It
does **not** load the host JupyterLab JavaScript bundle. Instead it ships its
own `@jupyterlab/*` packages resolved from `yarn.lock`.

- Most `@jupyterlab/*` packages resolve to **4.2.5**.
- Notable exceptions: `@jupyterlab/apputils` → **4.3.5**,
  `@jupyterlab/services` → **7.2.5**, `@jupyterlab/coreutils` → **6.2.5**.
- Declared ranges are still mostly `^4.0.0` (and related 4.x lines), so a rebuild
  against newer 4.x is allowed by policy.

Installing JupyterLab 4.4 / 4.5 / 4.6 in the Python environment therefore
**does not automatically upgrade** the Voilà frontend JS. It mainly affects:

- Building Voilà from source (`jupyterlab~=4.0` in the build system).
- Third-party labextensions discovered under
  `{PREFIX}/share/jupyter/labextensions`, which Voilà loads similarly to
  JupyterLab.

## Evidence from the repository

### Python packaging

| Location | Constraint | Role |
| --- | --- | --- |
| `pyproject.toml` build-system | `jupyterlab~=4.0` | Build only (`>=4.0,<5.0`) |
| `pyproject.toml` runtime | `jupyterlab_server>=2.3.0,<3` | Runtime (not `jupyterlab` itself) |
| Classifiers | JupyterLab 3 and 4 | Metadata; JupyterLab 3 is stale for 0.5.x |

`jupyterlab` is **not** a runtime dependency of the `voila` wheel. The preview
extension is installed as a prebuilt labextension packaged with Voilà.

### JavaScript packages

| Package | JupyterLab range |
| --- | --- |
| `@voila-dashboards/jupyterlab-preview` | `@jupyterlab/*`: `^4.0.0` |
| `@voila-dashboards/voila` | mostly `^4.0.0`; some packages `^4.2.5` |
| Widgets managers | `@jupyterlab/*`: `^4.0.0` (and matching services/coreutils lines) |

There are **no** `peerDependencies` that would restrict the host below 5.0.

### CI

Workflows install a broad 4.x range (`jupyterlab~=4.0` or `>=4,<5`) and verify
the preview extension. They do **not** matrix-test pinned 4.4, 4.5, or 4.6
releases. CI therefore exercises whatever current 4.x `pip` resolves at run
time, not each minor explicitly.

### Historical notes

- Voilà **0.5.0** rebuilt the frontend on JupyterLab **4.0** components
  (plugin-based app; nbextensions/requirejs path removed).
- Voilà **0.5.12** added the JupyterLab 4 packaging classifier.
- Older README / preview docs that mention JupyterLab 1.0+ or “3.0+ only” are
  partially stale; the current `0.5.x` stack targets **JupyterLab 4.x**.

## Risk areas on 4.5.x / 4.6.x

These spots are more sensitive when the host or shared federated packages move
ahead of the vendored 4.2.5 line:

1. **Custom `ThemeManager`** implementing `IThemeManager`
   (`packages/voila/src/plugins/themes/thememanager.ts`) — may need updates if
   the interface gains required members.
2. **`DirListing` / file browser overrides**
   (`packages/voila/src/plugins/tree/`) — subclasses protected/internal APIs.
3. **Deep imports** into `@jupyterlab/services/lib/...` from the widgets
   managers and kernelspec helpers — internal paths, not a stable public API.
4. **Module Federation shared-package skew** — third-party extensions built for
   newer JupyterLab minors may disagree with Voilà’s shared 4.2.5-era packages.
5. **Legacy `mathjax2-extension`** pinned at the 4.0.0 line alongside the newer
   MathJax extension.

The preview extension’s use of standard public APIs is the lower-risk surface
for host JupyterLab 4.4–4.6.

## Practical guidance

- **Using Voilà’s JupyterLab preview** on JupyterLab 4.4.x, 4.5.x, or 4.6.x:
  supported by declared ranges and JupyterLab’s 4.x extension compatibility
  policy. After install, confirm with:

  ```bash
  jupyter labextension list
  ```

  Look for `@voila-dashboards/jupyterlab-preview` as enabled/OK.

- **Running `voila` standalone** (lab template): works independently of the host
  JupyterLab minor; frontend JS is the vendored 4.2.5-based build unless you
  rebuild from source against newer packages.

- **Loading custom labextensions / themes into Voilà**: prefer extensions built
  for JupyterLab 4.x. Extensions compiled only for much newer minors may hit
  shared-dependency mismatches until Voilà’s frontend lockfile is refreshed.

- **JupyterLab 5**: out of range (`<5`); not supported by current constraints.

## Recommended verification (not yet in CI)

To empirically confirm a given minor:

```bash
python -m pip install "jupyterlab==4.4.*"   # or 4.5.*, 4.6.*
python -m pip install -e .
jupyter labextension list
python -m jupyterlab.browser_check
# Smoke-test: open a notebook, use Voilà Preview; run `voila <notebook>`
```

Adding an explicit JupyterLab minor matrix in CI would strengthen the
“verified” status beyond the current range-based support claim.

## Related documentation

- {ref}`install` — installing Voilà
- {doc}`customize` — themes, labextensions, and preview layout
- {doc}`contribute` — developing the JupyterLab preview extension
