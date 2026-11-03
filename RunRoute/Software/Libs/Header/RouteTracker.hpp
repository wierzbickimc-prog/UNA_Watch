/**
 ******************************************************************************
 * @file    RouteTracker.hpp
 * @brief   Follows a loaded route: where the runner is on it, the stretch to
 *          draw ahead, and when to raise the off-course alarm.
 *
 * The route file is written by tools/gpx2route.py (or later a phone app):
 *   "URTE", uint32 count, then count pairs of int32 latitude and longitude in
 *   units of 1e-7 degrees, all little-endian.
 ******************************************************************************
 */

#ifndef ROUTE_TRACKER_HPP
#define ROUTE_TRACKER_HPP

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

#include "Track.hpp"

class RouteTracker
{
public:
    static constexpr uint32_t kMaxPoints   = 4000;
    static constexpr float    kViewAheadM  = 91.44f;  ///< 300 ft drawn ahead
    static constexpr float    kViewBehindM = 9.144f;  ///< 30 ft drawn behind
    static constexpr float    kOffCourseM  = 45.72f;  ///< 150 ft counts as off course
    static constexpr float    kBackOnM     = 30.48f;  ///< 100 ft counts as back on
    static constexpr uint32_t kOffCourseSec = 10;     ///< How long before the alarm
    static constexpr uint32_t kRepeatSec    = 60;     ///< Alarm again while still off
    static constexpr float    kFinishM      = 20.0f;  ///< This close to the end is done

    enum class Event { None, WentOff, StillOff, BackOn };

    static constexpr float feetToMetres(int32_t feet) { return static_cast<float>(feet) * 0.3048f; }

    /// What counts as off course, back on and finished. Keeps the route.
    void setLimits(float offCourseM, float backOnM, uint32_t offCourseSec, uint32_t repeatSec, float finishM)
    {
        mOffCourseM   = offCourseM;
        mBackOnM      = backOnM;
        mOffCourseSec = offCourseSec;
        mRepeatSec    = repeatSec;
        mFinishM      = finishM;
    }

    /// Replace the route from file contents. False leaves no route.
    bool load(const uint8_t* data, size_t size)
    {
        mPoints.clear();
        reset();
        constexpr size_t kHeader = 8;
        if (data == nullptr || size < kHeader || std::memcmp(data, "URTE", 4) != 0) {
            return false;
        }
        const uint32_t count = readU32(data + 4);
        if (count < 2 || count > kMaxPoints || size != kHeader + count * size_t{8}) {
            return false;
        }

        const double lat0 = readI32(data + kHeader) * 1e-7;
        const double lon0 = readI32(data + kHeader + 4) * 1e-7;
        mLat0 = lat0;
        mLon0 = lon0;
        mMetresPerDegLon = kMetresPerDegLat * std::cos(lat0 * kPi / 180.0);

        mPoints.reserve(count);
        float along = 0.0f;
        for (uint32_t i = 0; i < count; ++i) {
            const uint8_t* entry = data + kHeader + i * size_t{8};
            Point p {};
            toLocal(readI32(entry) * 1e-7, readI32(entry + 4) * 1e-7, p.x, p.y);
            if (i > 0) {
                along += std::hypot(p.x - mPoints.back().x, p.y - mPoints.back().y);
            }
            p.along = along;
            mPoints.push_back(p);
        }
        return true;
    }

    /// Start a new run on the same route.
    void reset()
    {
        mStarted  = false;
        mJoined   = false;
        mOff      = false;
        mDone     = false;
        mHeading  = 0.0f;
        mHasMotion = false;
        mHasAnchor = false;
        mSegment  = 0;
        mAlong    = 0.0f;
        mDistance = 0.0f;
        mFarSince = 0;
        mLastAlarm = 0;
        mFar      = false;
    }

    bool hasRoute() const
    {
        return !mPoints.empty();
    }

    /// Feed one GPS position per second of running time.
    Event update(uint32_t sec, double lat, double lon)
    {
        if (!hasRoute()) {
            return Event::None;
        }
        toLocal(lat, lon, mX, mY);
        updateHeading();

        const bool following = mStarted && mJoined && !mOff;
        Match match = search(following ? mSegment : 0, following);
        if (following && match.distance > mBackOnM) {
            match = search(0, false);
        }
        mStarted  = true;
        mSegment  = match.segment;
        mAlong    = match.along;
        mDistance = match.distance;
        if (!mHasMotion) {
            mHeading = segmentHeading(mSegment);
        }

        if (!mJoined) {
            mJoined = mDistance <= mBackOnM;
            return Event::None;
        }
        if (mDone) {
            return Event::None;
        }
        if (mDistance <= mBackOnM && mAlong >= total() - mFinishM) {
            const bool wasOff = mOff;
            mOff  = false;
            mDone = true;
            return wasOff ? Event::BackOn : Event::None;
        }
        return updateAlarm(sec);
    }

    Track::RouteView view() const
    {
        Track::RouteView out {};
        out.status = status();
        if (out.status == Track::RouteStatus::NO_ROUTE) {
            return out;
        }
        out.offCourseM = mDistance;
        out.remainingM = std::max(0.0f, total() - mAlong);
        if (mStarted) {
            fillLine(out);
        }
        return out;
    }

private:
    struct Point {
        float x;
        float y;
        float along;
    };
    struct Match {
        uint32_t segment;
        float    along;
        float    distance;
    };

    float    mOffCourseM   = kOffCourseM;
    float    mBackOnM      = kBackOnM;
    uint32_t mOffCourseSec = kOffCourseSec;
    uint32_t mRepeatSec    = kRepeatSec;
    float    mFinishM      = kFinishM;

    static constexpr double kMetresPerDegLat = 111320.0;
    static constexpr double kPi = 3.14159265358979323846;
    static constexpr float  kMinMoveM     = 6.0f;    ///< Ignores GPS wander when standing
    static constexpr float  kAheadWindowM = 200.0f;  ///< How far a following search looks
    static constexpr float  kBackWindowM  = 50.0f;
    static constexpr float  kWrongWayCostM = 15.0f;

    static uint32_t readU32(const uint8_t* p)
    {
        return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
               (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
    }

    static int32_t readI32(const uint8_t* p)
    {
        return static_cast<int32_t>(readU32(p));
    }

    float total() const
    {
        return mPoints.back().along;
    }

    void toLocal(double lat, double lon, float& x, float& y) const
    {
        x = static_cast<float>((lon - mLon0) * mMetresPerDegLon);
        y = static_cast<float>((lat - mLat0) * kMetresPerDegLat);
    }

    Track::RouteStatus status() const
    {
        if (!hasRoute()) {
            return Track::RouteStatus::NO_ROUTE;
        }
        if (!mStarted) {
            return Track::RouteStatus::WAITING;
        }
        if (mDone) {
            return Track::RouteStatus::DONE;
        }
        if (!mJoined) {
            return Track::RouteStatus::TO_START;
        }
        return mOff ? Track::RouteStatus::OFF_COURSE : Track::RouteStatus::ON_COURSE;
    }

    /// The best point from segment @p from on. Where a route doubles back along
    /// the same road, two costs pick the right leg: one for facing against the
    /// runner's travel, and a small one per metre ahead for the earlier leg.
    Match search(uint32_t from, bool windowed) const
    {
        const float origin = mPoints[from].along;
        Match best {from, origin, -1.0f};
        float bestScore = 0.0f;
        uint32_t first = windowed ? from : 0;
        while (windowed && first > 0 && mPoints[first].along > mAlong - kBackWindowM) {
            --first;
        }
        for (uint32_t i = first; i + 1 < mPoints.size(); ++i) {
            const Point& a = mPoints[i];
            const Point& b = mPoints[i + 1];
            if (windowed && a.along > mAlong + kAheadWindowM) {
                break;
            }
            const float dx = b.x - a.x;
            const float dy = b.y - a.y;
            const float lengthSq = dx * dx + dy * dy;
            float t = lengthSq > 0.0f ? ((mX - a.x) * dx + (mY - a.y) * dy) / lengthSq : 0.0f;
            t = std::clamp(t, 0.0f, 1.0f);
            const float distance = std::hypot(mX - (a.x + dx * t), mY - (a.y + dy * t));
            const float along = a.along + (b.along - a.along) * t;
            float score = distance + 0.05f * std::max(0.0f, along - mAlong);
            if (mHasMotion && std::cos(std::atan2(dx, dy) - mHeading) < 0.0f) {
                score += kWrongWayCostM;
            }
            if (best.distance < 0.0f || score < bestScore) {
                best = {i, along, distance};
                bestScore = score;
            }
        }
        return best;
    }

    float segmentHeading(uint32_t segment) const
    {
        const Point& a = mPoints[segment];
        const Point& b = mPoints[segment + 1];
        return std::atan2(b.x - a.x, b.y - a.y);
    }

    void updateHeading()
    {
        if (!mHasAnchor) {
            mAnchorX = mX;
            mAnchorY = mY;
            mHasAnchor = true;
            return;
        }
        const float dx = mX - mAnchorX;
        const float dy = mY - mAnchorY;
        if (std::hypot(dx, dy) < kMinMoveM) {
            return;
        }
        const float moved = std::atan2(dx, dy);
        if (mHasMotion) {
            const float turn = std::remainder(moved - mHeading, static_cast<float>(2.0 * kPi));
            mHeading += turn * 0.5f;
        } else {
            mHeading = moved;
        }
        mHasMotion = true;
        mAnchorX = mX;
        mAnchorY = mY;
    }

    Event updateAlarm(uint32_t sec)
    {
        if (mOff) {
            if (mDistance <= mBackOnM) {
                mOff = false;
                mFar = false;
                return Event::BackOn;
            }
            if (sec - mLastAlarm >= mRepeatSec) {
                mLastAlarm = sec;
                return Event::StillOff;
            }
            return Event::None;
        }
        if (mDistance <= mOffCourseM) {
            mFar = false;
            return Event::None;
        }
        if (!mFar) {
            mFar = true;
            mFarSince = sec;
        }
        if (sec - mFarSince < mOffCourseSec) {
            return Event::None;
        }
        mOff = true;
        mLastAlarm = sec;
        return Event::WentOff;
    }

    /// A point at @p along on the route, turned so that travel is straight up.
    void addLinePoint(Track::RouteView& out, float along, uint32_t segment) const
    {
        const Point& a = mPoints[segment];
        const Point& b = mPoints[segment + 1];
        const float length = b.along - a.along;
        const float t = length > 0.0f ? std::clamp((along - a.along) / length, 0.0f, 1.0f) : 0.0f;
        const float dx = a.x + (b.x - a.x) * t - mX;
        const float dy = a.y + (b.y - a.y) * t - mY;
        const float c = std::cos(mHeading);
        const float s = std::sin(mHeading);
        constexpr float kLimit = 32000.0f;
        const float right   = std::clamp((dx * c - dy * s) * 10.0f, -kLimit, kLimit);
        const float forward = std::clamp((dx * s + dy * c) * 10.0f, -kLimit, kLimit);
        out.x[out.count] = static_cast<int16_t>(right);
        out.y[out.count] = static_cast<int16_t>(forward);
        ++out.count;
    }

    void fillLine(Track::RouteView& out) const
    {
        const float from = std::max(0.0f, mAlong - kViewBehindM);
        const float to   = std::min(total(), mAlong + kViewAheadM);

        uint32_t first = mSegment;
        while (first > 0 && mPoints[first].along > from) {
            --first;
        }
        uint32_t last = mSegment;
        while (last + 2 < mPoints.size() && mPoints[last + 1].along < to) {
            ++last;
        }

        // Inner vertices, thinned evenly if the stretch has more than fit.
        const uint32_t inner = last - first;
        const uint32_t room  = Track::RouteView::kMaxPoints - 2;
        const uint32_t step  = inner > room ? inner / room + 1 : 1;

        addLinePoint(out, from, first);
        for (uint32_t i = first + 1; i <= last; i += step) {
            addLinePoint(out, mPoints[i].along, i);
        }
        addLinePoint(out, to, last);
    }

    std::vector<Point> mPoints;
    double mLat0 = 0.0;
    double mLon0 = 0.0;
    double mMetresPerDegLon = kMetresPerDegLat;
    float  mX = 0.0f;
    float  mY = 0.0f;
    float  mAnchorX = 0.0f;
    float  mAnchorY = 0.0f;
    bool   mHasAnchor = false;
    bool   mHasMotion = false;
    float  mHeading = 0.0f;  ///< Radians clockwise from north
    bool   mStarted = false;
    bool   mJoined  = false;  ///< Has reached the route, so the alarm applies
    bool   mOff     = false;
    bool   mDone    = false;
    bool   mFar     = false;  ///< Past the limit, but not yet for long enough
    uint32_t mSegment = 0;
    float  mAlong    = 0.0f;
    float  mDistance = 0.0f;
    uint32_t mFarSince  = 0;
    uint32_t mLastAlarm = 0;
};

#endif // ROUTE_TRACKER_HPP
