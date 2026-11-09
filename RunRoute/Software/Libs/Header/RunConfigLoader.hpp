/**
 ******************************************************************************
 * @file    RunConfigLoader.hpp
 * @brief   Reads RunConfig from app_config.json. Service only.
 ******************************************************************************
 */

#ifndef RUN_CONFIG_LOADER_HPP
#define RUN_CONFIG_LOADER_HPP

#include "RunConfig.hpp"
#include "ScreenLayout.hpp"
#include "SDK/Kernel/Kernel.hpp"

RunConfig loadRunConfig(const SDK::Kernel& kernel);

/// The run screens from screens.json, or the defaults.
ScreenLayout loadScreenLayout(const SDK::Kernel& kernel);

#endif  // RUN_CONFIG_LOADER_HPP
