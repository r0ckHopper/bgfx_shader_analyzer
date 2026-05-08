
# bgfx_shader_analyzer

Language server for [bgfx](https://github.com/bkaradzic/bgfx) cross-platform shader files (`.sc`).

Based on [glsl_analyzer](https://github.com/nolanderc/glsl_analyzer) with bgfx-specific extensions for `$input`, `$output`, `$raw` directives, bgfx macros (`SAMPLER2D`, `IMAGE2D_RW`, etc.), and built-in uniforms.

- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
    - [Neovim](#neovim)


## Features

- **Completion** for bgfx built-in uniforms, macros, and GLSL functions/types
  
https://github.com/user-attachments/assets/314c29ea-dcf5-4992-bd74-c2883b1bed98
- **Go-to-definition** for `$input`/`$output` symbols and `SAMPLER2D`-declared variables
- **Hover documentation** for bgfx functions and built-ins

https://github.com/user-attachments/assets/788bd8d0-a0ae-49f5-a885-e78e38733584
- **Formatting** that preserves `$input`/`$output` structure
- **Parsing** of `$input`, `$output`, and `$raw` directives


## Installation

### Building from Source

Requires [Zig](https://ziglang.org/) 0.14.0.

```sh
zig build install -Doptimize=ReleaseSafe --prefix ~/.local/
```

This produces the `bgfx_shader_analyzer` binary.


## Usage

By default the server communicates over stdin/stdout:

```sh
bgfx_shader_analyzer
```

Use a TCP port instead:

```sh
bgfx_shader_analyzer --port <PORT>
```


### Neovim

Using native `vim.lsp.config` (Neovim 0.11+):

```lua
vim.lsp.config.bgfx_shader_analyzer = {
    cmd = { 'bgfx_shader_analyzer' },
    filetypes = { 'glsl', 'sc' },
    root_markers = { '.git' },
}
vim.lsp.enable('bgfx_shader_analyzer')
```


## Known Limitations

- Platform-conditional code (HLSL/Metal/SPIR-V paths in `#ifdef` blocks) is not analyzed
- bgfx macros are resolved semantically, not expanded textually
- `varying.def.sc` integration is not yet connected — types default to `vec4`
- No diagnostic validation of `$input`/`$output` against `varying.def.sc` yet
