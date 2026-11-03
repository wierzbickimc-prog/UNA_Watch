/**
 ******************************************************************************
 * @file    RunZoneAlerts.hpp
 * @brief   SDK::Workout::ZoneAlerts, with its timings set at run time. The SDK's
 *          are compile-time constants.
 ******************************************************************************
 */

#ifndef RUN_ZONE_ALERTS_HPP
#define RUN_ZONE_ALERTS_HPP

#include "SDK/Workout/WorkoutAlerts.hpp"

#include <cstdint>

class RunZoneAlerts {
public:
    using Alert = SDK::Workout::ZoneAlerts::Alert;
    using Zone  = SDK::Workout::Zone;

    void setTimings(uint32_t quietStartSec, uint32_t repeatSec)
    {
        mQuietStartSec = quietStartSec;
        mRepeatSec     = repeatSec;
    }

    void stepStarted()
    {
        mStepSec    = 0;
        mSinceAlert = 0;
        mAlerted    = Zone::Unknown;
    }

    Alert tick(Zone zone)
    {
        ++mStepSec;
        if (mAlerted != Zone::Unknown) {
            ++mSinceAlert;
        }
        switch (zone) {
        case Zone::In:
            if (mAlerted != Zone::Unknown) {
                mAlerted = Zone::Unknown;
                return Alert::BackIn;
            }
            return Alert::None;
        case Zone::Above:
        case Zone::Below:
            if (mStepSec <= mQuietStartSec) {
                return Alert::None;
            }
            if (zone != mAlerted || mSinceAlert >= mRepeatSec) {
                mAlerted    = zone;
                mSinceAlert = 0;
                return zone == Zone::Above ? Alert::Above : Alert::Below;
            }
            return Alert::None;
        default:
            return Alert::None;
        }
    }

private:
    uint32_t mQuietStartSec = SDK::Workout::ZoneAlerts::kQuietStartSec;
    uint32_t mRepeatSec     = SDK::Workout::ZoneAlerts::kRepeatSec;
    uint32_t mStepSec       = 0;
    uint32_t mSinceAlert    = 0;
    Zone     mAlerted       = Zone::Unknown;
};

#endif  // RUN_ZONE_ALERTS_HPP
