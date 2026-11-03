/**
 ******************************************************************************
 * @file    RunConfig.hpp
 * @brief   The numbers RouteSync on the Mac can change. It writes them to
 *          app_config.json in the app's folder, and the service reads them when
 *          the app starts and sends them to the GUI. A missing or bad value
 *          falls back to the default here.
 *
 *          RouteSync's RunSettings.swift holds the same list, with the same
 *          defaults and limits, and its tests compare the two.
 ******************************************************************************
 */

#ifndef RUN_CONFIG_HPP
#define RUN_CONFIG_HPP

#include <cstdint>

struct RunConfig {
    int32_t thresholdPaceSec = 510;  ///< Seconds per mile
    int32_t weightLb         = 165;
    int32_t maxHr            = 197;
    int32_t vo2BaselinePct   = 20;   ///< How far each run moves the usual VO2max

    int32_t conditionFresh   = 3;    ///< This and above is Fresh
    int32_t conditionNormal  = -2;   ///< This and above is Normal
    int32_t conditionTired   = -7;   ///< This and above is Tired; below is Struggling

    int32_t zoneQuietSec     = 20;   ///< No target alerts this early in a step
    int32_t zoneRepeatSec    = 30;   ///< Alert again while still outside the target

    int32_t routeOffFt       = 150;  ///< This far away counts as off course
    int32_t routeBackFt      = 100;  ///< This close counts as back on
    int32_t routeDelaySec    = 10;   ///< How long before the alarm
    int32_t routeRepeatSec   = 60;   ///< Alarm again while still off
    int32_t routeFinishFt    = 66;   ///< This close to the end is done
};

#endif  // RUN_CONFIG_HPP
