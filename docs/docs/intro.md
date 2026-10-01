---
slug: /
sidebar_position: 1
title: Introduction
---

# Vitellus

Vitellus is a rendering hardware interface (RHI) written in Zig. One API sits on top of Vulkan and DirectX 12, so you can write a renderer or game engine once and run it on either.

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
| Metal | macOS, iOS | Planned |

You can also register your own backends. See [Backends and validation](./concepts/backends.md).

## Where to go next

- [Getting started](./getting-started.md): add Vitellus to a project.
- [Your first triangle](./guide/first-triangle.md): open a window, then clear it and draw.
- [API reference](pathname:///api/): the Zig-generated docs for every public declaration.
