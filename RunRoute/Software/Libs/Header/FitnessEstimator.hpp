/**
 ******************************************************************************
 * @file    FitnessEstimator.hpp
 * @brief   Estimates VO2max and performance condition from pace and heart rate.
 *
 * Each steady second gives one VO2max estimate: the oxygen cost of the current
 * speed (Daniels-Gilbert) over the share of VO2max the current heart rate
 * implies (Swain, %HRmax = 0.64 * %VO2max + 37). These are population formulas,
 * so the results are estimates, best read as a trend.
 ******************************************************************************
 */

#ifndef FITNESS_ESTIMATOR_HPP
#define FITNESS_ESTIMATOR_HPP

#include <algorithm>
#include <cmath>
#include <cstdint>

class FitnessEstimator
{
public:
    static constexpr float    kMaxHr          = 197.0f;  ///< The runner's maximum, bpm
    static constexpr uint32_t kWarmupSec      = 300;     ///< Ignored at the start of a run
    static constexpr uint32_t kWindowSec      = 60;      ///< Effort must hold steady this long
    static constexpr uint32_t kConditionSec   = 60;      ///< Steady time before condition shows
    static constexpr uint32_t kVo2MaxSec      = 600;     ///< Steady time before VO2max counts
    static constexpr int      kConditionLimit = 20;      ///< Condition is shown as +/- this

    /// The VO2max a speed (m/s) and heart rate (bpm) imply, or 0 if outside the
    /// range the formulas hold for: running pace, and at least 60% of max HR.
    static float estimate(float speedMs, float hr, float maxHr = kMaxHr)
    {
        const float hrFraction = hr / maxHr;
        if (speedMs < kMinSpeedMs || hrFraction < 0.60f || hrFraction > 0.98f) {
            return 0.0f;
        }
        const float metersPerMin = speedMs * 60.0f;
        const float cost = -4.60f + 0.182258f * metersPerMin + 0.000104f * metersPerMin * metersPerMin;
        const float vo2Fraction = (hrFraction - 0.37f) / 0.64f;
        const float vo2max = cost / vo2Fraction;
        return vo2max >= 20.0f && vo2max <= 85.0f ? vo2max : 0.0f;
    }

    void reset()
    {
        const float maxHr = mMaxHr;
        *this = FitnessEstimator{};
        mMaxHr = maxHr;
    }

    void setMaxHr(float maxHr)
    {
        mMaxHr = maxHr;
    }

    /// Feed the current values. Call it as often as you like: only the first call
    /// in each second of @p activeSec counts. A pause shows up as a gap in time.
    void add(uint32_t activeSec, float speedMs, float hr, bool usable)
    {
        if (mStarted && activeSec == mLastSec) {
            return;
        }
        if (!usable || speedMs <= 0.0f || (mStarted && activeSec > mLastSec + 2)) {
            mFilled = 0;
        }
        mStarted = true;
        mLastSec = activeSec;
        if (!usable || speedMs <= 0.0f) {
            return;
        }

        mSpeed[mNext] = speedMs;
        mHr[mNext]    = hr;
        mNext = (mNext + 1) % kWindowSec;
        mFilled = std::min(mFilled + 1, kWindowSec);

        if (activeSec < kWarmupSec || mFilled < kWindowSec) {
            return;
        }
        const float estimated = steadyEstimate();
        if (estimated <= 0.0f) {
            return;
        }
        mSum += estimated;
        ++mSteadySec;
        // A running average that settles into the last couple of minutes, so
        // condition does not jump around or lean on its first reading.
        mCurrent += (estimated - mCurrent) / static_cast<float>(std::min<uint32_t>(mSteadySec, 120));
        if (mSteadySec == kConditionSec) {
            mFirst = mCurrent;
            mLowest = mCurrent;
        } else if (mSteadySec > kConditionSec) {
            mLowest = std::min(mLowest, mCurrent);
        }
    }

    /// This run's VO2max, or 0 until it has enough steady running.
    float vo2max() const
    {
        return mSteadySec >= kVo2MaxSec ? mSum / static_cast<float>(mSteadySec) : 0.0f;
    }

    bool conditionReady() const
    {
        return mSteadySec >= kConditionSec;
    }

    /// Today's fitness against @p baseline, in percent. Negative means the same
    /// effort is costing more heart rate than usual.
    int condition(float baseline) const
    {
        return percentOf(mCurrent, baseline);
    }

    /// Condition when it first appeared this run.
    int conditionStart(float baseline) const
    {
        return percentOf(mFirst, baseline);
    }

    /// The lowest condition this run.
    int conditionLowest(float baseline) const
    {
        return percentOf(mLowest, baseline);
    }

    /// The new baseline once a run of @p vo2 is saved: slow to move, so that one
    /// odd run does not rewrite what "usual" means.
    static float nextBaseline(float baseline, float vo2, float share = 0.2f)
    {
        if (vo2 <= 0.0f) {
            return baseline;
        }
        return baseline > 0.0f ? baseline + (vo2 - baseline) * share : vo2;
    }

private:
    float mMaxHr = kMaxHr;

    static constexpr float kMinSpeedMs = 2.2f;  ///< About 12:10 per mile; slower is walking

    static int percentOf(float value, float baseline)
    {
        if (baseline <= 0.0f || value <= 0.0f) {
            return 0;
        }
        const int percent = static_cast<int>(std::lround((value - baseline) / baseline * 100.0f));
        return std::clamp(percent, -kConditionLimit, kConditionLimit);
    }

    float steadyEstimate() const
    {
        const auto speed = std::minmax_element(mSpeed, mSpeed + kWindowSec);
        const auto hr    = std::minmax_element(mHr, mHr + kWindowSec);
        float speedSum = 0.0f;
        float hrSum    = 0.0f;
        for (uint32_t i = 0; i < kWindowSec; ++i) {
            speedSum += mSpeed[i];
            hrSum    += mHr[i];
        }
        const float speedAvg = speedSum / kWindowSec;
        const float hrAvg    = hrSum / kWindowSec;
        // Heart rate lags effort, so only a settled stretch means anything.
        if (*speed.second - *speed.first > 0.2f * speedAvg || *hr.second - *hr.first > 10.0f) {
            return 0.0f;
        }
        return estimate(speedAvg, hrAvg, mMaxHr);
    }

    float    mSpeed[kWindowSec] = {};
    float    mHr[kWindowSec]    = {};
    uint32_t mNext      = 0;
    uint32_t mFilled    = 0;
    uint32_t mLastSec   = 0;
    bool     mStarted   = false;
    float    mSum       = 0.0f;
    uint32_t mSteadySec = 0;
    float    mCurrent   = 0.0f;
    float    mFirst     = 0.0f;
    float    mLowest    = 0.0f;
};

#endif // FITNESS_ESTIMATOR_HPP
