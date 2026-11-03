// Prints how UNA's own FitWorkoutReader reads a workout file, so the tests can
// check that files the app writes are ones the watch accepts. The tests build this
// when una-sdk/ is present.
#include "SDK/Fit/FitWorkoutReader.hpp"
#include <cstdio>
#include <vector>

using namespace SDK::Workout;

static SDK::Fit::FitWorkoutReader reader;
static Program p;

int main(int, char** argv)
{
    FILE* f = std::fopen(argv[1], "rb");
    if (!f) return 2;
    std::vector<uint8_t> data(1 << 20);
    const size_t size = std::fread(data.data(), 1, data.size(), f);
    std::fclose(f);
    SDK::Fit::MemoryByteSource source(data.data(), size);
    const auto result = reader.read(source, p);
    std::printf("%s\n", SDK::Fit::FitWorkoutReader::resultName(result));
    if (result != SDK::Fit::FitWorkoutReader::Result::Ok) return 1;
    std::printf("workout|%s|%u|%u|%d\n", p.name, p.sport, p.stepCount, p.degraded);
    for (int i = 0; i < p.stepCount; ++i) {
        const Step& s = p.steps[i];
        std::printf("step|%d|%u|%u|%u|%u|%d|%s|", (int)s.end, s.durationMs, s.distanceCm, s.repeatFrom, s.repeatCount,
                    (int)s.intensity, s.notes);
        std::printf("target|%d|%u|%u|%d|%u|%u\n", (int)s.target, s.speedLowMmps, s.speedHighMmps, (int)s.hrKind,
                    s.hrLow, s.hrHigh);
    }
    return 0;
}
