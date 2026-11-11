//! Renderer-level errors: which step failed. Vulkan's own codes are `vk.Error`;
//! call sites map them with `vk.createDevice(...) catch return error.FailedToCreateDevice;`.
pub const Errors = error{
    // acquires
    FailedToAcquireNextImage,
    // allocate
    FailedToAllocateBufferMemory,
    FailedToAllocateCommandBuffer,
    FailedToAllocateCommandBuffers,
    FailedToAllocateDescriptorSets,
    FailedToAllocateImageMemory,
    // begins
    FailedToBeginCommandBuffer,
    FailedToBeginRecordingCommandBuffer,
    // binds
    FailedToBindBufferMemory,
    FailedToBindImageMemory,
    // create
    FailedToCreateBuffer,
    FailedToCreateCommandPool,
    FailedToCreateDevice,
    FailedToCreateDescriptorPool,
    FailedToCreateDescriptorSetLayout,
    FailedToCreateFence,
    FailedToCreateFramebuffer,
    FailedToCreateImage,
    FailedToCreateImageView,
    FailedToCreateInstance,
    FailedToCreatePipeline,
    FailedToCreatePipelineLayout,
    FailedToCreateSemaphore,
    FailedToCreateShaderModule,
    FailedToCreateSurface,
    FailedToCreateSwapchain,
    FailedToCreateRenderPass,
    FailedToCreateTextureImageView,
    FailedToCreateTextureSampler,
    // end
    FailedToEndCommandBuffer,
    // enumerate
    FailedToEnumerateDeviceExtensions,
    FailedToEnumerateInstanceExtensions,
    FailedToEnumeratePhysicalDevice,
    // get
    FailedToGetNumSwapchainImages,
    FailedToGetPhysicalDeviceSurfaceCapabilities,
    FailedToGetPhysicalDeviceSurfaceFormatsKHR,
    FailedToGetPhysicalDeviceSurfacePresentModesKHR,
    FailedToGetPhysicalDeviceSurfaceSupport,
    FailedToGetQueueFamilyIndices,
    FailedToGetSwapchainImages,
    // find
    FailedToFindSuitableMemoryType,
    // idle
    FailedToIdleDevice,
    FailedToIdleQueue,
    // misc
    FailedToMapMemory,
    FailedToPresentQueue,
    FailedToRecordCommandBuffer,
    // resets
    FailedToResetCommandBuffer,
    FailedToResetFences,
    // submits
    FailedToSubmitDrawCommandBuffer,
    FailedToSubmitQueue,
    FailedToWaitForFence,
    // missing
    MissingRequiredInstanceExtension,
    // physical devices
    NoPhysicalDevicesSupportVulkan,
    NoPhysicalDevicesAreSuitableForApp,
    UnsupportedLayoutTransition,
};
