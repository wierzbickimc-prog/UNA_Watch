/**
 ******************************************************************************
 * @file    RouteCatalog.hpp
 * @brief   The routes in the app's Routes folder, and which one is selected. A
 *          route's name is its file name without ".bin".
 ******************************************************************************
 */

#ifndef ROUTE_CATALOG_HPP
#define ROUTE_CATALOG_HPP

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

class RouteCatalog
{
public:
    static constexpr size_t  kMaxRoutes = 32;
    static constexpr size_t  kNameBytes = 40;
    static constexpr int16_t kNone      = -1;

    void clear()
    {
        mCount    = 0;
        mSelected = kNone;
    }

    /// Add a file from the folder. False if it is not a route, or there is no room.
    bool add(const char* fileName)
    {
        const size_t length = std::strlen(fileName);
        constexpr size_t kExtension = 4;
        if (mCount >= kMaxRoutes || length <= kExtension || length - kExtension >= kNameBytes ||
            fileName[0] == '.' || std::strcmp(fileName + length - kExtension, ".bin") != 0) {
            return false;
        }
        char* name = mNames[mCount].data();
        std::memcpy(name, fileName, length - kExtension);
        name[length - kExtension] = '\0';
        ++mCount;
        return true;
    }

    /// Alphabetical, whatever order the file system gave.
    void sort()
    {
        std::sort(mNames.begin(), mNames.begin() + mCount, [](const Name& a, const Name& b) {
            return std::strcmp(a.data(), b.data()) < 0;
        });
    }

    size_t size() const
    {
        return mCount;
    }

    const char* name(size_t index) const
    {
        return mNames[index].data();
    }

    /// The route's path from the app's folder. False if @p index is not a route.
    bool path(int16_t index, char* out, size_t capacity) const
    {
        if (index < 0 || static_cast<size_t>(index) >= mCount) {
            return false;
        }
        const int written = std::snprintf(out, capacity, "Routes/%s.bin", name(static_cast<size_t>(index)));
        return written > 0 && static_cast<size_t>(written) < capacity;
    }

    int16_t selected() const
    {
        return mSelected;
    }

    void select(int16_t index)
    {
        mSelected = index >= 0 && static_cast<size_t>(index) < mCount ? index : kNone;
    }

    /// Select by name; a name that is no longer there selects nothing, rather
    /// than quietly running a different route.
    void selectName(const char* wanted)
    {
        mSelected = kNone;
        for (size_t i = 0; i < mCount; ++i) {
            if (std::strcmp(name(i), wanted) == 0) {
                mSelected = static_cast<int16_t>(i);
                return;
            }
        }
    }

private:
    using Name = std::array<char, kNameBytes>;

    std::array<Name, kMaxRoutes> mNames {};
    size_t  mCount    = 0;
    int16_t mSelected = kNone;
};

#endif // ROUTE_CATALOG_HPP
