// Host test for TrainingLoad. From this folder:
//   c++ -std=c++17 -I../Libs/Header TrainingLoadTest.cpp -o /tmp/load_test && /tmp/load_test

#include "TrainingLoad.hpp"

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

static RunLoad steady(uint32_t seconds, float speed, float grade = 0.0f, bool gradeValid = true)
{
    RunLoad r;
    for (uint32_t t = 0; t < seconds; ++t) {
        r.add(t, speed, grade, gradeValid);
    }
    return r;
}

int main()
{
    const float threshold = RunLoad::kThresholdSpeedMs;

    check("nothing yet", RunLoad{}.intensity() == 0.0f && RunLoad{}.load() == 0.0f);
    const RunLoad hour = steady(3600, threshold);
    check("an hour at threshold is 100", near(hour.load(), 100.0f, 0.5f));
    check("threshold is intensity 1", near(hour.intensity(), 1.0f, 0.01f));
    const RunLoad easy = steady(3600, threshold * 0.8f);
    check("easier counts for less", near(easy.load(), 64.0f, 0.5f) && near(easy.intensity(), 0.8f, 0.01f));
    check("half an hour counts half", near(steady(1800, threshold).load(), 50.0f, 0.5f));

    check("uphill counts for more", steady(600, threshold, 5.0f).intensity() > 1.1f);
    check("downhill counts for less", steady(600, threshold, -5.0f).intensity() < 0.95f);
    check("no grade reading changes nothing", near(steady(600, threshold, 20.0f, false).intensity(), 1.0f, 0.01f));
    check("a wild grade is limited", near(steady(600, threshold, 200.0f).intensity(), 1.495f, 0.01f));
    check("a GPS spike is limited", near(steady(600, threshold * 10.0f).intensity(), 2.0f, 0.01f));

    RunLoad repeated;
    for (uint32_t t = 0; t < 1800; ++t) {
        repeated.add(t, threshold, 0.0f, true);
        repeated.add(t, threshold, 0.0f, true);
    }
    check("repeat calls in one second count once", near(repeated.load(), 50.0f, 0.5f));

    check("known date", Training::dayFromYmd(20261102) == 20759);
    check("day after a month end", Training::dayFromYmd(20270101) - Training::dayFromYmd(20261231) == 1);
    check("leap day counts", Training::dayFromYmd(20280301) - Training::dayFromYmd(20280228) == 2);

    const Training seed = Training::seed();
    check("starts from today's values", seed.fitness == 12.0f && seed.fatigue == 24.0f && seed.vo2Baseline == 51.0f);

    Training rest = seed;
    rest.advanceTo(seed.day + 7);
    check("fatigue falls faster than fitness", near(rest.fatigue, 24.0f * std::exp(-1.0f), 0.01f) &&
                                               near(rest.fitness, 12.0f * std::exp(-1.0f / 6.0f), 0.01f));

    Training backwards = seed;
    backwards.advanceTo(seed.day - 3);
    check("a clock going back changes nothing", backwards.day == seed.day && backwards.fitness == 12.0f);

    Training run = seed;
    run.addLoad(seed.day + 1, 100.0f);
    check("a run lifts fatigue most",
          near(run.fatigue, 24.0f * std::exp(-1.0f / 7.0f) + 100.0f * (1.0f - std::exp(-1.0f / 7.0f)), 0.01f) &&
          near(run.fitness, 12.0f * std::exp(-1.0f / 42.0f) + 100.0f * (1.0f - std::exp(-1.0f / 42.0f)), 0.01f));

    Training twice = seed;
    twice.addLoad(seed.day + 1, 40.0f);
    twice.addLoad(seed.day + 1, 60.0f);
    check("two runs in a day add up", near(twice.fitness, run.fitness, 0.01f) && near(twice.fatigue, run.fatigue, 0.01f));

    Training held = {};
    for (int i = 0; i < 400; ++i) {
        held.addLoad(static_cast<uint32_t>(i), 50.0f);
    }
    check("a steady load settles at that load", near(held.fitness, 50.0f, 0.5f) && near(held.fatigue, 50.0f, 0.5f));

    std::printf(sFailures ? "%d FAILED\n" : "all passed\n", sFailures);
    return sFailures ? 1 : 0;
}
