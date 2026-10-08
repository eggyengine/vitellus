---
slug: /
sidebar_position: 1
title: Introduction
---

# Vitellus

Vitellus is a rendering hardware interface (RHI) written in Zig. One API sits on top of Vulkan, DirectX 12 and WebGPU, so you can write a renderer or game engine once and run it on any of them, including in the browser.

It stays close to the hardware. You create the devices, queues, swapchains, pipelines and command buffers yourself, and you record barriers and synchronisation yourself. Vitellus handles the parts that differ between backends: picking a backend, loading the driver, translating shaders and reflecting their bindings.

## What's in the box

| Area | Types |
| --- | --- |
| Setup | `Instance`, `Adapter`, `Device`, `Queue` |
| Presentation | `Window`, `Swapchain` |
| Resources | `Buffer`, `Texture`, `TextureView`, `Sampler` |
| Shaders | `Shader`, `SPIRVShaderModule`, `HLSLShaderModule`, `BinaryShaderModule` |
| Pipelines | `GraphicsPipeline`, `ComputePipeline`, `PipelineLayout` |
| Bindings | `BindGroupLayout`, `BindGroup` |
| Recording | `CommandPool`, `CommandBuffer`, `QuerySet` |
| Synchronisation | `Fence` (timeline), `Semaphore` |

Each type is exported from the root module, and its descriptor sits next to it (`Buffer` and `BufferDescriptor`, for example). The lower-level enums and structs live under `vitellus.hal.<area>`, such as `vitellus.hal.command.ColorAttachment`.

## Backends

| Backend | Platforms | Status |
| --- | --- | --- |
| Vulkan | Linux, Windows, Android | Supported |
| DirectX 12 | Windows | Supported |
| WebGPU | Browsers, through Emscripten | Supported (see [Deploying to the web](./guide/web.md)) |
| Metal | macOS, iOS | Planned |

You can also register your own backends. See [Backends and validation](./concepts/backends.md).

## Where to go next

- [Getting started](./getting-started.md): add Vitellus to a project.
- [Your first triangle](./guide/first-triangle.md): open a window, then clear it and draw.
- [Deploying to the web](./guide/web.md): build for WebGPU with Emscripten and host the page.
- [API reference](pathname:///api/): the Zig-generated docs for every public declaration.
