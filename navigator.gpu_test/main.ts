// Basic WebGPU initialization in Deno
const gpu = navigator.gpu;
if (!gpu) {
  console.error("WebGPU not supported in this Deno environment");
  Deno.exit(1);
}

// Request an adapter (physical GPU device)
const adapter = await gpu.requestAdapter();
if (!adapter) {
  console.error("Couldn't request WebGPU adapter");
  Deno.exit(1);
}

// Get the preferred format for canvas rendering
// Useful when working with canvas in browser/Deno environments
const preferredFormat = gpu.getPreferredCanvasFormat();
console.log(`Preferred canvas format: ${preferredFormat}`);

// Create a device with default settings
const device = await adapter.requestDevice();
console.log("WebGPU device created successfully");
