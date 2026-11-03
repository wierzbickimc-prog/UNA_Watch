/**
 ******************************************************************************
 * @file    TrainingSerializer.hpp
 * @brief   Reads and writes the fitness history as JSON. Each app writes its own
 *          copy, and reads the other's to pick up runs recorded there.
 ******************************************************************************
 */

#ifndef TRAINING_SERIALIZER_HPP
#define TRAINING_SERIALIZER_HPP

#include "SDK/Kernel/Kernel.hpp"

#include "TrainingLoad.hpp"

class TrainingSerializer {
public:
    explicit TrainingSerializer(const SDK::Kernel& kernel);

    bool save(const char* path, const Training& training);
    bool load(const char* path, Training& training);

private:
    const SDK::Kernel& mKernel;
};

#endif // TRAINING_SERIALIZER_HPP
