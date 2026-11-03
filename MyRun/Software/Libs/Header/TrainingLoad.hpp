/**
 ******************************************************************************
 * @file    TrainingLoad.hpp
 * @brief   Intensity and load for a run, and the fitness, fatigue and form they
 *          build up, in the manner of intervals.icu.
 *
 * Load is the running form of training stress: one hour at threshold pace is
 * 100. Without power, effort comes from pace, adjusted roughly for the grade.
 * Fitness and fatigue are 42 and 7 day exponentially weighted averages of the
 * daily load. Only runs recorded on the watch count.
 ******************************************************************************
 */

#ifndef TRAINING_LOAD_HPP
#define TRAINING_LOAD_HPP

#include <algorithm>
#include <cmath>
#include <cstdint>

/// Intensity and load of the current run.
class RunLoad
{
public:
    static constexpr float kThresholdSpeedMs = 1609.344f / 510.0f;  ///< 8:30 per mile

    void reset()
    {
        *this = RunLoad{};
    }

    /// Feed the current values. Only the first call in each second of
    /// @p activeSec counts.
    void add(uint32_t activeSec, float speedMs, float gradePct, bool gradeValid)
    {
        if (mStarted && activeSec == mLastSec) {
            return;
        }
        mStarted = true;
        mLastSec = activeSec;
        const float adjusted = speedMs * gradeFactor(gradePct, gradeValid);
        const float relative = std::min(adjusted / kThresholdSpeedMs, kMaxRelative);
        mSumSquares += relative * relative;
        ++mSeconds;
    }

    /// Effort against threshold: 1.0 is threshold pace held throughout.
    float intensity() const
    {
        return mSeconds > 0 ? std::sqrt(mSumSquares / static_cast<float>(mSeconds)) : 0.0f;
    }

    float load() const
    {
        return mSumSquares / 36.0f;
    }

private:
    static constexpr float kMaxRelative = 2.0f;  ///< Keeps a GPS spike from counting for much

    /// Rule of thumb: each 1% uphill costs about 3.3% more, each 1% downhill
    /// saves about 1.8%.
    static float gradeFactor(float gradePct, bool valid)
    {
        if (!valid) {
            return 1.0f;
        }
        const float grade = std::clamp(gradePct, -15.0f, 15.0f);
        return grade >= 0.0f ? 1.0f + 0.033f * grade : 1.0f + 0.018f * grade;
    }

    float    mSumSquares = 0.0f;
    uint32_t mSeconds    = 0;
    uint32_t mLastSec    = 0;
    bool     mStarted    = false;
};

/// What carries over between runs.
struct Training {
    uint32_t day         = 0;      ///< Days since 1970 that fitness and fatigue are for
    float    fitness     = 0.0f;
    float    fatigue     = 0.0f;
    float    vo2Baseline = 0.0f;   ///< Usual VO2max
    uint32_t savedUtc    = 0;      ///< When written; the newest copy wins

    /// Days since 1970 from a date as the number yyyymmdd.
    static uint32_t dayFromYmd(uint32_t ymd)
    {
        int year = static_cast<int>(ymd / 10000);
        const int month = static_cast<int>(ymd / 100 % 100);
        const int date  = static_cast<int>(ymd % 100);
        year -= month <= 2 ? 1 : 0;
        const int era = year / 400;
        const int yearOfEra = year - era * 400;
        const int dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + date - 1;
        const int dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
        return static_cast<uint32_t>(era * 146097 + dayOfEra - 719468);
    }

    /// The starting point, from intervals.icu and the Garmin on 2 November 2026.
    static Training seed()
    {
        Training t;
        t.day         = dayFromYmd(20261102);
        t.fitness     = 12.0f;
        t.fatigue     = 24.0f;
        t.vo2Baseline = 51.0f;
        return t;
    }

    /// Bring the averages forward to @p today, as rest days with no load.
    void advanceTo(uint32_t today)
    {
        if (today <= day) {
            return;  // includes a clock that went backwards
        }
        const float days = static_cast<float>(today - day);
        fitness *= std::exp(-days / kFitnessDays);
        fatigue *= std::exp(-days / kFatigueDays);
        day = today;
    }

    /// Count a run on @p today. A second run on one day adds to the first.
    void addLoad(uint32_t today, float load)
    {
        advanceTo(today);
        fitness += load * (1.0f - std::exp(-1.0f / kFitnessDays));
        fatigue += load * (1.0f - std::exp(-1.0f / kFatigueDays));
    }

private:
    static constexpr float kFitnessDays = 42.0f;
    static constexpr float kFatigueDays = 7.0f;
};

#endif // TRAINING_LOAD_HPP
