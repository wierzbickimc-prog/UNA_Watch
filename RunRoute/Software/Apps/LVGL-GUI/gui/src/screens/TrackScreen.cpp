/**
 ******************************************************************************
 * @file    TrackScreen.cpp
 * @brief   The live activity screen (see TrackScreen.hpp).
 ******************************************************************************
 */

#include "gui/screens/TrackScreen.hpp"
#include "gui/screens/ScreenManager.hpp"
#include "gui/theme/Theme.hpp"
#include "gui/Assets.hpp"
#include "gui/Format.hpp"
#include "gui/Strings.hpp"

#include <algorithm>
#include <cstring>

#include "SDK/Utils/ClockTime.hpp"
#include "SDK/Workout/WorkoutProgram.hpp"

using namespace SDK::GUI;
using F = Theme::Font;

namespace
{
// Status face clock geometry (TrackFaceStatus.hpp).
constexpr int32_t kTimeY       = 63;
constexpr int32_t kMeridiemY   = 105;
constexpr int32_t kMeridiemGap = 5;

// Interval phase accents (TrackFaceIntervals).
constexpr uint32_t kIvNeutral = Color::WHITE;
constexpr uint32_t kIvRun     = Color::CYAN;
// Route face: the runner's place, and 300 ft of route above it.
constexpr int32_t kRouteRunnerY       = 180;
constexpr float   kRoutePxPerDecimetre = 165.0f / 914.4f;
constexpr float   kRouteAwayPx         = 65.0f;  ///< Off course, the route is this far from the runner
constexpr float   kRouteZoomOutM       = 24.4f;  ///< 80 ft from the route starts the zoomed-out view

constexpr uint32_t kIvRest    = Color::WHITE;  // amber means too slow on a workout

const char* phaseTitle(Track::IntervalsPhase phase)
{
    switch (phase) {
        case Track::IntervalsPhase::RUN:       return "RUN";
        case Track::IntervalsPhase::REST:      return "REST";
        case Track::IntervalsPhase::COOL_DOWN: return "COOL DOWN";
        default:                               return "WARM UP";
    }
}

RunConfig sCondition;  ///< The cut-offs, from onShow()

const char* conditionWord(int condition)
{
    return condition >= sCondition.conditionFresh ? "Fresh" : condition >= sCondition.conditionNormal ? "Normal" : condition >= sCondition.conditionTired ? "Tired" : "Struggling";
}

uint32_t conditionColor(int condition)
{
    return condition >= sCondition.conditionFresh ? Color::GREEN : condition >= sCondition.conditionNormal ? Color::WHITE : condition >= sCondition.conditionTired ? Color::YELLOW : Color::RED;
}

void setHidden(lv_obj_t* obj, bool hidden)
{
    if (hidden) {
        lv_obj_add_flag(obj, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_remove_flag(obj, LV_OBJ_FLAG_HIDDEN);
    }
}
} // namespace

TrackScreen::TrackScreen(Model& model)
    : Screen(model)
{
}

void TrackScreen::build()
{
    mIndicator = std::make_unique<Widgets::ScrollIndicator>(mRoot, Widgets::ScrollIndicator::kSmall);
    mButtons = std::make_unique<Widgets::Buttons>(mRoot);
    mButtons->set(Widgets::Buttons::NONE, Widgets::Buttons::NONE,
                  Widgets::Buttons::NONE, Widgets::Buttons::AMBER);

    buildFaceStatus();
    buildFaceRoute();
    buildFaceCondition();
    buildFaceIntervals();
    mDataFace = std::make_unique<DataFace>(mRoot);

    mWorkoutGauge = std::make_unique<WorkoutFaceGauge>(mRoot);
    mWorkoutStep  = std::make_unique<WorkoutFaceStep>(mRoot);
    mWorkoutNext  = std::make_unique<WorkoutStepCard>(mRoot);
}

void TrackScreen::buildFaceIntervals()
{
    lv_obj_t* f = mFaceIntervals = Theme::container(mRoot, 0, 0, 240, 240);
    mIvRepeats     = Theme::label(f, F::Italic18, "", 80, 202, 80);
    mIvRunIcon     = Theme::image(f, &img_runningman_46x46, 97, 167);
    mIvHr          = Theme::label(f, F::SemiBold35, Strings::kNoValue, 40, 162, 160);
    mIvPace        = Theme::label(f, F::SemiBold35, Strings::kNoValue, 40, 162, 160);
    mIvHeartIcon   = Theme::image(f, &img_heart_30x30, 105, 137);
    mIvPaceIcon    = Theme::image(f, &img_pace_30x30, 105, 137);
    mIntervalsTimer = std::make_unique<Widgets::IntervalsTimer>(f, 25, 41);
    mIntervalsTitle = std::make_unique<Widgets::Title>(f, "WARM UP");
}

void TrackScreen::buildFaceRoute()
{
    lv_obj_t* f = mFaceRoute = Theme::container(mRoot, 0, 0, 240, 240);
    mRouteLine = lv_line_create(f);
    lv_obj_set_pos(mRouteLine, 0, 0);
    lv_obj_set_size(mRouteLine, 240, 240);
    lv_obj_set_style_line_width(mRouteLine, 7, LV_PART_MAIN);
    lv_obj_set_style_line_rounded(mRouteLine, true, LV_PART_MAIN);
    lv_obj_set_style_line_color(mRouteLine, Theme::rgb(Color::CYAN_PURE), LV_PART_MAIN);
    mRouteRunner = Theme::dot(f, 120 - 8, kRouteRunnerY - 8, 8, Color::WHITE);
    mRouteTitle = Theme::label(f, F::Medium25, "", 0, 22, 240);
    mRouteNote  = Theme::label(f, F::SemiBold20, "", 0, 202, 240);
}

void TrackScreen::setRoute(const Track::RouteView& view)
{
    // Away from the route, zoom out around the runner so the way back shows,
    // starting before the alarm: the line can leave the screen well before then.
    const bool away = view.status == Track::RouteStatus::OFF_COURSE ||
                      view.status == Track::RouteStatus::TO_START ||
                      (view.status == Track::RouteStatus::ON_COURSE && view.offCourseM > kRouteZoomOutM);
    const int32_t runnerY = away ? 120 : kRouteRunnerY;
    float scale = kRoutePxPerDecimetre;
    if (away && view.offCourseM > 0.0f) {
        scale = std::min(scale, kRouteAwayPx / (view.offCourseM * 10.0f));
    }
    lv_obj_set_pos(mRouteRunner, 120 - 8, runnerY - 8);

    const uint8_t count = view.count <= Track::RouteView::kMaxPoints ? view.count : Track::RouteView::kMaxPoints;
    for (uint8_t i = 0; i < count; ++i) {
        mRoutePoints[i].x = static_cast<lv_value_precise_t>(120 + view.x[i] * scale);
        mRoutePoints[i].y = static_cast<lv_value_precise_t>(runnerY - view.y[i] * scale);
    }
    lv_line_set_points(mRouteLine, mRoutePoints, count);

    char note[24];
    switch (view.status) {
        case Track::RouteStatus::NO_ROUTE:
            setRouteTitle("No route", Color::WHITE);
            snprintf(note, sizeof(note), "Choose in Routes");
            break;
        case Track::RouteStatus::WAITING:
            setRouteTitle("Route ready", Color::WHITE);
            snprintf(note, sizeof(note), "Waiting for GPS");
            break;
        case Track::RouteStatus::TO_START:
            setRouteTitle("To route", Color::YELLOW);
            formatRouteDistance(note, sizeof(note), view.offCourseM, "away");
            break;
        case Track::RouteStatus::OFF_COURSE:
            setRouteTitle("OFF COURSE", Color::RED);
            formatRouteDistance(note, sizeof(note), view.offCourseM, "off");
            break;
        case Track::RouteStatus::DONE:
            setRouteTitle("Route done", Color::GREEN);
            snprintf(note, sizeof(note), " ");
            break;
        default:
            setRouteTitle("", Color::WHITE);
            formatRouteDistance(note, sizeof(note), view.remainingM, "left");
            break;
    }
    lv_label_set_text(mRouteNote, note);

    // The alarm brings the route up, whichever face was showing.
    if (view.status == Track::RouteStatus::OFF_COURSE && mRouteStatus != view.status) {
        const uint8_t route = mScreens.find(ScreenLayout::Kind::ROUTE);
        if (route < mScreens.count) {
            showFace(static_cast<uint16_t>(kScreenBase + route));
        }
    }
    mRouteStatus = view.status;
}

void TrackScreen::setRouteTitle(const char* text, uint32_t color)
{
    lv_label_set_text(mRouteTitle, text);
    lv_obj_set_style_text_color(mRouteTitle, Theme::rgb(color), 0);
}

void TrackScreen::formatRouteDistance(char* buf, size_t n, float metres, const char* suffix) const
{
    constexpr float kFeetPerMetre = 3.28084f;
    if (metres * kFeetPerMetre < 1000.0f) {
        snprintf(buf, n, "%u ft %s", static_cast<unsigned>(metres * kFeetPerMetre), suffix);
        return;
    }
    char miles[12];
    Fmt::fixed(miles, sizeof(miles), metres / 1609.344f, 2);
    snprintf(buf, n, "%s mi %s", miles, suffix);
}

void TrackScreen::onRouteData(const Track::RouteView& view)
{
    if (!mLeaving) {
        setRoute(view);
    }
}

void TrackScreen::buildFaceCondition()
{
    lv_obj_t* f = mFaceCondition = Theme::container(mRoot, 0, 0, 240, 240);
    Theme::label(f, F::Italic18, "Condition", 0, 40, 240);
    mConditionValue = Theme::label(f, F::SemiBold60, Strings::kNoValue, 0, 66, 240);
    Theme::hline(f, 35, 150, 170);
    mConditionWord = Theme::label(f, F::Medium25, "", 0, 158, 240);
    mIntensityValue = Theme::label(f, F::Italic18, "", 0, 194, 240);
}

void TrackScreen::setCondition(const Track::Data& data)
{
    const char* word = "Warm-up";
    uint32_t color   = Color::WHITE;
    if (data.conditionStatus == Track::ConditionStatus::NO_BASELINE) {
        word = "First run";
    } else if (data.conditionStatus == Track::ConditionStatus::READY) {
        word  = conditionWord(data.condition);
        color = conditionColor(data.condition);
    }
    if (data.conditionStatus == Track::ConditionStatus::READY) {
        lv_label_set_text_fmt(mConditionValue, "%+d", data.condition);
    } else {
        lv_label_set_text(mConditionValue, Strings::kNoValue);
    }
    lv_label_set_text(mConditionWord, word);
    lv_obj_set_style_text_color(mConditionWord, lv_color_hex(color), 0);

    char intensity[12];
    char line[24];
    Fmt::fixed(intensity, sizeof(intensity), data.intensity, 2);
    snprintf(line, sizeof(line), "Intensity %s", intensity);
    lv_label_set_text(mIntensityValue, line);
}

void TrackScreen::buildFaceStatus()
{
    lv_obj_t* f = mFaceStatus = Theme::container(mRoot, 0, 0, 240, 240);
    mSensorRow = std::make_unique<Widgets::SensorStatusRow>(f, 0, 20, 240, 24);
    Theme::hline(f, 35, 62, 170);
    // Digits and AM/PM are sized to their text and centred as a group in setTime().
    mDayTime = Theme::label(f, F::SemiBold60, "--:--", 0, kTimeY, LV_SIZE_CONTENT, LV_TEXT_ALIGN_LEFT);
    mMeridiem = Theme::label(f, F::Medium18, "AM", 0, kMeridiemY, LV_SIZE_CONTENT, LV_TEXT_ALIGN_LEFT);
    lv_obj_add_flag(mMeridiem, LV_OBJ_FLAG_HIDDEN);
    Theme::hline(f, 35, 136, 170);
    mBattery = std::make_unique<Widgets::Battery>(f, 76, 153);
    mPercent = Theme::label(f, F::Medium25, "0%", 42, 187, 157);
}

const uint16_t* TrackScreen::faces(uint16_t& count) const
{
    count = mFaceCount;
    return mFaces;
}

void TrackScreen::buildFaceList()
{
    mFaceCount = 0;
    if (mMode == Mode::Workout) {
        mFaces[mFaceCount++] = FaceId::ID_WORKOUT_GAUGE;
        mFaces[mFaceCount++] = FaceId::ID_WORKOUT_STEP;
        mFaces[mFaceCount++] = FaceId::ID_WORKOUT_NEXT;
    } else if (mMode == Mode::Intervals) {
        mFaces[mFaceCount++] = FaceId::ID_INTERVALS;
    }
    for (uint8_t i = 0; i < mScreens.count; ++i) {
        mFaces[mFaceCount++] = static_cast<uint16_t>(kScreenBase + i);
    }
}

uint16_t TrackScreen::faceIndex(uint16_t id) const
{
    uint16_t count = 0;
    const uint16_t* list = faces(count);
    for (uint16_t i = 0; i < count; ++i) {
        if (list[i] == id) {
            return i;
        }
    }
    return count;
}

void TrackScreen::updateMode(const Track::Data& data)
{
    const Mode mode = data.workoutMode   ? Mode::Workout
                    : data.intervalsMode ? Mode::Intervals
                                         : Mode::Free;
    if (mModeSet && mode == mMode) {
        return;
    }
    mModeSet = true;
    mMode    = mode;
    buildFaceList();
    mIndicator->setCount(mFaceCount);
    // A face the run no longer has (a workout completed or ended) falls back
    // to the first one it has.
    showFace(mFaceId);
}

void TrackScreen::onShow()
{
    mLeaving = false;
    sCondition = mModel.getRunConfig();
    mModel.menu().track.action.reset();

    mIsImperial       = mModel.isUnitsImperial();
    mIs12Hour         = mModel.is12HourFormat();
    mHrThresholdCount = mModel.getHrThresholdsCount() < App::Config::kHrThresholdsCount
                            ? mModel.getHrThresholdsCount()
                            : static_cast<uint8_t>(App::Config::kHrThresholdsCount);
    memcpy(mHrThresholds, mModel.getHrThresholds(), mHrThresholdCount);
    mDataContext.imperial         = mIsImperial;
    mDataContext.is12Hour         = mIs12Hour;
    mDataContext.weightLb         = static_cast<float>(sCondition.weightLb);
    mDataContext.hrThresholds     = mHrThresholds;
    mDataContext.hrThresholdCount = mHrThresholdCount;
    mDataContext.battery          = mModel.getBatteryLevel();
    mDataContext.conditionFresh   = sCondition.conditionFresh;
    mDataContext.conditionNormal  = sCondition.conditionNormal;
    mDataContext.conditionTired   = sCondition.conditionTired;
    {
        uint8_t h = 0, m = 0, sec = 0;
        mModel.getTime(h, m, sec);
        mDataContext.hour   = h;
        mDataContext.minute = m;
    }
    // A new layout comes with the settings, so pick it up on each show.
    mScreens = mModel.getScreenLayout();
    mModeSet = false;

    // Set the mode before the face so that showFace() can fall back to the
    // first face the run has, and the scroll indicator count fits.
    const Track::Data& data = mModel.getTrackData();
    mFaceId = mModel.menu().track.get();
    updateMode(data);

    // Coming back from a cool-down alert, show the intervals face regardless of
    // where the user had scrolled, so the cool-down phase is visible.
    const bool forceIntervals = mMode == Mode::Intervals &&
        mModel.getPendingAlertIntervals().phase == Track::IntervalsPhase::COOL_DOWN;
    showFace(forceIntervals ? static_cast<uint16_t>(FaceId::ID_INTERVALS) : mModel.menu().track.get());

    onTrackData(data);
    mRouteStatus = mModel.getRouteView().status;
    setRoute(mModel.getRouteView());
    setWorkoutStep(mModel.getWorkoutStep(false));
    mWorkoutNext->showNext(mModel.getWorkoutStep(true));
    setWorkoutFace(mModel.getWorkoutFace());
    uint8_t h = 0, m = 0, s = 0;
    mModel.getTime(h, m, s);
    setTime(h, m);
    onBatteryLevel(mModel.getBatteryLevel());
    onGpsFix(mModel.hasGpsFix());
    onAccessoryStatus(mModel.getAccessoryState(), "");

    // A step that started while another screen showed gets its card before
    // this screen (ScreenManager::goTo()). This catches one that started
    // after that choice was made.
    if (mModel.takeStepCard()) {
        showStepCard();
    }
}

void TrackScreen::onHide()
{
    mModel.menu().track.set(mFaceId);
}

void TrackScreen::showFace(uint16_t id)
{
    uint16_t count = 0;
    const uint16_t* list = faces(count);
    uint16_t index = faceIndex(id);
    if (index >= count) {
        index = 0;
    }
    if (count == 0) {
        return;
    }
    id      = list[index];
    mFaceId = id;
    using Kind = ScreenLayout::Kind;
    const bool layout = id >= kScreenBase && id - kScreenBase < mScreens.count;
    const Kind kind   = layout ? mScreens.screens[id - kScreenBase].kind : Kind::COUNT;
    setHidden(mFaceIntervals,         id != FaceId::ID_INTERVALS);
    setHidden(mFaceRoute,             kind != Kind::ROUTE);
    setHidden(mFaceCondition,         kind != Kind::CONDITION);
    setHidden(mFaceStatus,            kind != Kind::STATUS);
    setHidden(mDataFace->root(),      kind != Kind::DATA);
    if (kind == Kind::DATA) {
        mDataFace->setScreen(mScreens.screens[id - kScreenBase]);
        mDataFace->show(mModel.getTrackData(), mDataContext);
    }
    setHidden(mWorkoutGauge->root(),  id != FaceId::ID_WORKOUT_GAUGE);
    setHidden(mWorkoutStep->root(),   id != FaceId::ID_WORKOUT_STEP);
    setHidden(mWorkoutNext->root(),   id != FaceId::ID_WORKOUT_NEXT);
    mIndicator->setActive(index);
}

void TrackScreen::showStepCard()
{
    // The card replaces this screen on the next frame. Until then the faces
    // are left as they are, so the new step does not show on them first.
    mLeaving = true;
    ScreenManager::instance().goTo(ScreenId::TrackWorkoutStep);
}

void TrackScreen::onKey(uint8_t code)
{
    namespace Btn = SDK::GUI::Button;
    uint16_t count = 0;
    const uint16_t* list = faces(count);
    const uint16_t index = faceIndex(mFaceId);
    switch (code) {
        case Btn::L1:
            showFace(list[index == 0 || index >= count ? count - 1 : index - 1]);
            break;
        case Btn::L2:
            showFace(list[index + 1 >= count ? 0 : index + 1]);
            break;
        case Btn::R1:
            ScreenManager::instance().goTo(ScreenId::TrackAction);
            break;
        case Btn::R2:
            // In Intervals or a structured workout the lap button moves to the
            // next phase or step, on any face; laps are step-driven. When the
            // workout completes the service drops the mode, so R2 then records
            // a manual lap. A free run always records a manual lap.
            if (mMode != Mode::Free) {
                mModel.intervalsNextPhase();
            } else {
                mModel.saveLap();
                ScreenManager::instance().goTo(ScreenId::TrackLap);
            }
            break;
        default:
            break;
    }
}

void TrackScreen::onTrackData(const Track::Data& data)
{
    if (mLeaving) {
        return;
    }
    // A workout that completes or is ended drops to a free run.
    updateMode(data);

    char buf[16];

    refreshDataFace();

    setCondition(data);

    // Workout faces: the live pace under a step with no target, the lap
    // averages on the step face.
    mLivePace = Fmt::paceUnits(data.pace, mIsImperial);
    mLapPace  = Fmt::paceUnits(data.lapPace, mIsImperial);
    mLapHr    = data.avgLapHR;
    mWorkoutStep->setAverages(mLapPace, mLapHr, mHeartRateStep);

    // Intervals face
    if (mMode == Mode::Intervals) {
        const Track::IntervalsData& iv = data.intervals;
        setIntervalsPhase(iv);
        if (iv.metric == Track::IntervalsMetric::DISTANCE) {
            mIntervalsTimer->setPhaseDistance(Fmt::distUnits(iv.distRemaining, mIsImperial), mIsImperial);
        } else {
            mIntervalsTimer->setPhaseTime(iv.phaseTimerSec, iv.metric);
        }
        Fmt::pace(buf, sizeof(buf), Fmt::paceUnits(data.pace, mIsImperial));
        lv_label_set_text(mIvPace, buf);
        Fmt::heartRate(buf, sizeof(buf), data.hr);
        lv_label_set_text(mIvHr, buf);
    }

    mHrSource = data.hrSource;
    updateHrIcon();
}

void TrackScreen::setIntervalsPhase(const Track::IntervalsData& iv)
{
    const bool run  = iv.phase == Track::IntervalsPhase::RUN;
    const bool rest = iv.phase == Track::IntervalsPhase::REST;

    mIntervalsTitle->setText(phaseTitle(iv.phase));
    mIntervalsTimer->setColor(run ? kIvRun : rest ? kIvRest : kIvNeutral);
    mIntervalsTimer->setLineVisible(run || rest);

    // Bottom row: pace while running, heart rate while resting, the runner otherwise.
    setHidden(mIvRunIcon,   run || rest);
    setHidden(mIvPaceIcon,  !run);
    setHidden(mIvPace,      !run);
    setHidden(mIvHeartIcon, !rest);
    setHidden(mIvHr,        !rest);

    // Repeat counter only during RUN / REST; "n" alone for open-ended repeats.
    setHidden(mIvRepeats, !(run || rest));
    if (iv.totalRepeats == 0) {
        lv_label_set_text_fmt(mIvRepeats, "%u", static_cast<unsigned>(iv.repeat));
    } else {
        lv_label_set_text_fmt(mIvRepeats, "%u/%u", static_cast<unsigned>(iv.repeat),
                              static_cast<unsigned>(iv.totalRepeats));
    }
}

void TrackScreen::onWorkoutData(const Model::WorkoutFace& face)
{
    if (mLeaving) {
        return;
    }
    setWorkoutFace(face);
}

void TrackScreen::onWorkoutStep(bool next)
{
    if (mLeaving) {
        return;
    }
    if (next) {
        mWorkoutNext->showNext(mModel.getWorkoutStep(true));
        return;
    }
    // onShow() shows the new step when the card hands back.
    if (mModel.takeStepCard()) {
        showStepCard();
        return;
    }
    setWorkoutStep(mModel.getWorkoutStep(false));
}

void TrackScreen::setWorkoutFace(const Model::WorkoutFace& face)
{
    mHeartRateStep = static_cast<SDK::Workout::Target>(face.target) == SDK::Workout::Target::HeartRate;
    mWorkoutGauge->set(face, mIsImperial, mLivePace);
    mWorkoutStep->setRepeat(face.rep, face.reps);
    mWorkoutStep->setAverages(mLapPace, mLapHr, mHeartRateStep);
}

void TrackScreen::setWorkoutStep(const Model::WorkoutStepInfo& step)
{
    mWorkoutStep->setStep(step);
    mWorkoutStep->setRepeat(step.rep, step.reps);
}

void TrackScreen::onBatteryLevel(uint8_t level)
{
    mBattery->setLevel(level);
    lv_label_set_text_fmt(mPercent, "%u%%", level);
    mDataContext.battery = level;
    refreshDataFace();
}

void TrackScreen::refreshDataFace()
{
    if (!mLeaving && mDataFace && !lv_obj_has_flag(mDataFace->root(), LV_OBJ_FLAG_HIDDEN)) {
        mDataFace->show(mModel.getTrackData(), mDataContext);
    }
}

void TrackScreen::onTime(uint8_t hour, uint8_t minute, uint8_t /*sec*/)
{
    setTime(hour, minute);
    if (hour != mDataContext.hour || minute != mDataContext.minute) {
        mDataContext.hour   = hour;
        mDataContext.minute = minute;
        refreshDataFace();
    }
}

void TrackScreen::setTime(uint8_t h, uint8_t m)
{
    const SDK::Clock::Hour12 civil = SDK::Clock::to12Hour(h);
    lv_label_set_text_fmt(mDayTime, "%u:%02u", mIs12Hour ? civil.hour : h, m);

    // Centre digits (+ suffix) as one group on the 240 px face, as the Run app does.
    lv_obj_update_layout(mDayTime);
    const int32_t timeW = lv_obj_get_width(mDayTime);
    int32_t groupW = timeW;
    int32_t merW   = 0;
    if (mIs12Hour) {
        lv_label_set_text(mMeridiem, civil.pm ? "PM" : "AM");
        lv_obj_remove_flag(mMeridiem, LV_OBJ_FLAG_HIDDEN);
        lv_obj_update_layout(mMeridiem);
        merW   = lv_obj_get_width(mMeridiem);
        groupW = timeW + kMeridiemGap + merW;
    } else {
        lv_obj_add_flag(mMeridiem, LV_OBJ_FLAG_HIDDEN);
    }
    const int32_t left = (240 - groupW) / 2;
    lv_obj_set_pos(mDayTime, left, kTimeY);
    if (mIs12Hour) {
        lv_obj_set_pos(mMeridiem, left + timeW + kMeridiemGap, kMeridiemY);
    }
}

void TrackScreen::onLapChanged(uint8_t /*lapEnd*/)
{
    ScreenManager::instance().goTo(ScreenId::TrackLap);
}

void TrackScreen::onIntervalsPhaseAlert()
{
    ScreenManager::instance().goTo(ScreenId::TrackIntervalsAlert);
}

void TrackScreen::onIntervalsWorkoutCompleted()
{
    ScreenManager::instance().goTo(ScreenId::TrackIntervalsCompleted);
}

void TrackScreen::onGpsFix(bool acquired)
{
    mSensorRow->setGps(Widgets::SensorStatusRow::gpsState(acquired));
}

void TrackScreen::onAccessoryStatus(uint8_t state, const char* /*name*/)
{
    mAccessoryState = state;
    updateHrIcon();
}

void TrackScreen::updateHrIcon()
{
    mSensorRow->setHr(Widgets::SensorStatusRow::hrStateFromSource(mAccessoryState, mHrSource));
}
