#include "RunConfigLoader.hpp"

#include <memory>
#include <new>

#include "SDK/AppConfig/AppConfig.hpp"

namespace {

using SDK::AppConfig;

// RouteSync's RunSettings.swift must match these. Its tests check.
constexpr AppConfig::Field kFields[] = {
    AppConfig::intField("thresholdPaceSec", 510, 240, 960),
    AppConfig::intField("weightLb", 165, 60, 400),
    AppConfig::intField("maxHr", 197, 120, 230),
    AppConfig::intField("vo2BaselinePct", 20, 0, 100),
    AppConfig::intField("conditionFresh", 3, -20, 20),
    AppConfig::intField("conditionNormal", -2, -20, 20),
    AppConfig::intField("conditionTired", -7, -20, 20),
    AppConfig::intField("zoneQuietSec", 20, 0, 300),
    AppConfig::intField("zoneRepeatSec", 30, 5, 600),
    AppConfig::intField("routeOffFt", 150, 30, 1000),
    AppConfig::intField("routeBackFt", 100, 10, 1000),
    AppConfig::intField("routeDelaySec", 10, 0, 120),
    AppConfig::intField("routeRepeatSec", 60, 10, 600),
    AppConfig::intField("routeFinishFt", 66, 10, 500),
};

}  // namespace

RunConfig loadRunConfig(const SDK::Kernel& kernel)
{
    RunConfig config;
    std::unique_ptr<AppConfig> file(new (std::nothrow) AppConfig(
        kernel, "app_config.json", kFields, sizeof(kFields) / sizeof(kFields[0])));
    if (!file) {
        return config;
    }
    config.thresholdPaceSec = file->getInt("thresholdPaceSec");
    config.weightLb         = file->getInt("weightLb");
    config.maxHr            = file->getInt("maxHr");
    config.vo2BaselinePct   = file->getInt("vo2BaselinePct");
    config.conditionFresh   = file->getInt("conditionFresh");
    config.conditionNormal  = file->getInt("conditionNormal");
    config.conditionTired   = file->getInt("conditionTired");
    config.zoneQuietSec     = file->getInt("zoneQuietSec");
    config.zoneRepeatSec    = file->getInt("zoneRepeatSec");
    config.routeOffFt       = file->getInt("routeOffFt");
    config.routeBackFt      = file->getInt("routeBackFt");
    config.routeDelaySec    = file->getInt("routeDelaySec");
    config.routeRepeatSec   = file->getInt("routeRepeatSec");
    config.routeFinishFt    = file->getInt("routeFinishFt");
    return config;
}
