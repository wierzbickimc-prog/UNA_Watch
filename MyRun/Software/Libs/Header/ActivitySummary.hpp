/**
 ******************************************************************************
 * @file    ActivitySummary.hpp
 * @date    08-04-2025
 * @author  Denys Saienko <denys.saienko@droid-technologies.com>
 * @brief   Represents a common summary track information.
 ******************************************************************************
 *
 ******************************************************************************
 */

#ifndef ACTIVITY_SUMMARY_HPP
#define ACTIVITY_SUMMARY_HPP

#include <cstdint>
#include <ctime>
#include <vector>

#include "SDK/TrackMap/TrackMapScreen.hpp"

/**
 * @struct LapSummary
 * @brief Summary data for a single lap.
 */
struct LapSummary {
    time_t duration;  ///< Lap duration in seconds
    float  distance;  ///< Lap distance in m
    float  paceAvg;   ///< Average pace in s/m
};

/**
 * @struct ActivitySummary
 * @brief Represents a common summary track information.
 */
struct ActivitySummary {
    time_t utc;         ///< Last activity UTC time
    time_t time;        ///< Total track time in seconds
    float distance;     ///< Total track distance in m
    float speedAvg;     ///< Average speed in m/s
    float elevation;    ///< Accumulated elevation gain (ascent) in m
    float paceAvg;      ///< Average pace in s/m
    float hrMax;        ///< Maximum Heart Rate in bpm
    float hrAvg;        ///< Average Heart Rate in bpm
    float vo2max;       ///< Estimated VO2max, or 0 without enough steady running
    float vo2Baseline;  ///< Usual VO2max before this run, or 0 if none yet
    float intensity;    ///< Effort against threshold; 1.0 is threshold pace
    float load;         ///< Training load of this run
    float fitness;      ///< Fitness with this run counted
    float fatigue;      ///< Fatigue with this run counted
    bool  conditionReady;  ///< The run reached a condition reading
    int8_t conditionStart; ///< Condition when it first appeared
    int8_t conditionLow;   ///< Lowest condition
    int8_t conditionEnd;   ///< Condition at the end
    SDK::TrackMapScreen map; ///< Track map

    std::vector<LapSummary> laps; ///< Per-lap summary data
};

#endif // ACTIVITY_SUMMARY_HPP
