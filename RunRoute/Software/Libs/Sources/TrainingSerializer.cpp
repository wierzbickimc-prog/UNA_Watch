#include "TrainingSerializer.hpp"

#include <memory>
#include <new>

#include "SDK/JSON/JsonStreamReader.hpp"
#include "SDK/JSON/JsonStreamWriter.hpp"

TrainingSerializer::TrainingSerializer(const SDK::Kernel& kernel)
    : mKernel(kernel)
{
}

bool TrainingSerializer::save(const char* path, const Training& training)
{
    std::unique_ptr<SDK::Interface::IFile> file = mKernel.fs.file(path);
    if (!file || !file->open(true, true)) {
        return false;
    }

    SDK::JsonStreamWriter writer(file.get());
    writer.startMap();
    writer.add("day", training.day);
    writer.add("fitness", training.fitness);
    writer.add("fatigue", training.fatigue);
    writer.add("vo2_baseline", training.vo2Baseline);
    writer.add("saved_utc", training.savedUtc);
    writer.endMap();

    file->flush();
    file->close();
    return true;
}

bool TrainingSerializer::load(const char* path, Training& training)
{
    std::unique_ptr<SDK::Interface::IFile> file = mKernel.fs.file(path);
    if (!file || !file->exist() || !file->open(false, false)) {
        return false;
    }

    constexpr size_t kMaxSize = 256;
    const size_t size = file->size();
    if (size == 0 || size > kMaxSize) {
        file->close();
        return false;
    }
    char buffer[kMaxSize];
    size_t read = 0;
    const bool ok = file->read(buffer, size, read) && read == size;
    file->close();
    if (!ok) {
        return false;
    }

    SDK::JsonStreamReader reader(buffer, size);
    if (!reader.validate()) {
        return false;
    }
    Training loaded;
    if (!reader.get("day", loaded.day) || !reader.get("fitness", loaded.fitness) ||
        !reader.get("fatigue", loaded.fatigue) || !reader.get("vo2_baseline", loaded.vo2Baseline)) {
        return false;
    }
    reader.get("saved_utc", loaded.savedUtc);
    training = loaded;
    return true;
}
