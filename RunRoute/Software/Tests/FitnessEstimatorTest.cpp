// Host test for FitnessEstimator. From this folder:
//   c++ -std=c++17 -I../Libs/Header FitnessEstimatorTest.cpp -o /tmp/fitness_test && /tmp/fitness_test

#include "FitnessEstimator.hpp"

#include <cmath>
#include <cstdio>

static int sFailures = 0;

static void check(const char* name, bool ok)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    sFailures += ok ? 0 : 1;
}

static bool near(float value, float expected, float tolerance)
{
    return std::fabs(value - expected) <= tolerance;
}

static constexpr float kMilePerMin9 = 1609.34f / 540.0f;  // 9:00 per mile, m/s

static FitnessEstimator steadyRun(uint32_t seconds, float speed, float hr)
{
    FitnessEstimator f;
    for (uint32_t t = 0; t < seconds; ++t) {
        f.add(t, speed, hr, true);
    }
    return f;
}

int main()
{
    check("9:00/mi at 150 bpm is about 51", near(FitnessEstimator::estimate(kMilePerMin9, 150.0f), 51.0f, 1.5f));
    check("walking pace is rejected", FitnessEstimator::estimate(1.5f, 150.0f) == 0.0f);
    check("low heart rate is rejected", FitnessEstimator::estimate(kMilePerMin9, 100.0f) == 0.0f);
    check("impossible result is rejected", FitnessEstimator::estimate(7.0f, 130.0f) == 0.0f);

    check("no condition during warm-up", !steadyRun(299, kMilePerMin9, 150.0f).conditionReady());
    check("condition by about 6 minutes", steadyRun(361, kMilePerMin9, 150.0f).conditionReady());
    check("no VO2max before enough steady running", steadyRun(800, kMilePerMin9, 150.0f).vo2max() == 0.0f);
    const FitnessEstimator full = steadyRun(1000, kMilePerMin9, 150.0f);
    check("VO2max after steady running", near(full.vo2max(), 51.0f, 1.5f));

    const float usual = full.vo2max();
    check("same effort reads as 0", full.condition(usual) == 0);
    check("higher heart rate reads negative", steadyRun(1000, kMilePerMin9, 160.0f).condition(usual) < 0);
    check("lower heart rate reads positive", steadyRun(1000, kMilePerMin9, 140.0f).condition(usual) > 0);
    check("no baseline reads as 0", full.condition(0.0f) == 0);
    check("condition stays in range", steadyRun(1000, kMilePerMin9, 150.0f).condition(20.0f) == 20);

    FitnessEstimator surging;
    for (uint32_t t = 0; t < 1000; ++t) {
        surging.add(t, t % 60 < 30 ? 2.5f : 4.5f, 150.0f, true);
    }
    check("surging pace does not count", !surging.conditionReady());

    FitnessEstimator wandering;
    for (uint32_t t = 0; t < 1000; ++t) {
        wandering.add(t, kMilePerMin9, t % 40 < 20 ? 135.0f : 165.0f, true);
    }
    check("swinging heart rate does not count", !wandering.conditionReady());

    // 400 steady seconds, which would pass the 600 needed if each counted twice.
    FitnessEstimator repeated;
    for (uint32_t t = 0; t < 700; ++t) {
        repeated.add(t, kMilePerMin9, 150.0f, true);
        repeated.add(t, kMilePerMin9, 150.0f, true);
    }
    check("repeat calls in one second count once", repeated.vo2max() == 0.0f);

    // 550 steady seconds, a pause, then 50 more: enough only if the window survives.
    FitnessEstimator paused = steadyRun(850, kMilePerMin9, 150.0f);
    for (uint32_t t = 1000; t < 1050; ++t) {
        paused.add(t, kMilePerMin9, 150.0f, true);
    }
    check("a pause restarts the steady window", paused.vo2max() == 0.0f);

    FitnessEstimator fading = steadyRun(800, kMilePerMin9, 150.0f);
    for (uint32_t t = 800; t < 1400; ++t) {
        fading.add(t, kMilePerMin9, t < 1100 ? 162.0f : 156.0f, true);
    }
    check("start keeps the first reading", fading.conditionStart(usual) == 0);
    check("lowest is below the end after recovering",
          fading.conditionLowest(usual) < fading.condition(usual) && fading.condition(usual) < 0);

    check("first run sets the baseline", FitnessEstimator::nextBaseline(0.0f, 50.0f) == 50.0f);
    check("later runs move it slowly", near(FitnessEstimator::nextBaseline(50.0f, 55.0f), 51.0f, 0.01f));
    check("a run without VO2max leaves it", FitnessEstimator::nextBaseline(50.0f, 0.0f) == 50.0f);

    check("a lower max heart rate changes the estimate",
          FitnessEstimator::estimate(kMilePerMin9, 150.0f, 180.0f) != FitnessEstimator::estimate(kMilePerMin9, 150.0f));
    check("the baseline share can be set", near(FitnessEstimator::nextBaseline(50.0f, 60.0f, 0.5f), 55.0f, 0.01f));

    std::printf(sFailures ? "%d FAILED\n" : "all passed\n", sFailures);
    return sFailures ? 1 : 0;
}
