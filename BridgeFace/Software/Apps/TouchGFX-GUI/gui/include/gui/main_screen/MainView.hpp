#ifndef MAINVIEW_HPP
#define MAINVIEW_HPP

#include <gui_generated/main_screen/MainViewBase.hpp>
#include <gui/main_screen/MainPresenter.hpp>

/**
 * @class MainView
 * @brief A photo of the bridge, with the time and the battery percentage.
 *
 * The screen comes from UNA's Smile face, whose generated code can't be remade
 * on a Mac, so this hides the widgets it doesn't use. The date line shows the
 * battery number instead, because its font has the digits. The percent sign is
 * part of the photo: see BridgeFace/tools/make_faces.py.
 */
class MainView : public MainViewBase
{
public:
    MainView();
    virtual ~MainView() {}
    virtual void setupScreen();
    virtual void tearDownScreen();

    /** @brief Set the clock, if the reading has changed. */
    void setTime(const WallTime &time);

    /** @brief Charge level pushed up from the service, 0-100. */
    void setBatteryLevel(uint8_t level);

    /** @brief This face shows no health readings, and the service sends none. */
    void setHealth(const DailyHealth &) {}

    /** @brief Adopt the clock format the watch is set to. */
    void setClockStyle(const ClockStyle &style);

private:
    /** Centre the hour, separator and minute as one group. */
    void layoutClock();

    /** Move a text area, repainting what it leaves as well as where it lands. */
    static void place(touchgfx::TextArea &area, int16_t x, int16_t width);

    /** Rewrite the clock's two number buffers from the reading on screen. */
    void updateClockText();

    /// Baselines must match make_faces.py: the font's baseline is 60 down from
    /// the top of the clock's box and 16 down from the top of the battery's.
    static const int16_t kClockY = 115;
    static const int16_t kClockHeight = 77;
    static const int16_t kBatteryY = 181;
    static const int16_t kBatteryHeight = 20;

    /// Where the percent sign starts in the photo.
    static const int16_t kPercentX = 126;

    /// The room between hour and minute: the colon sits in it in the 12-hour
    /// form, and it is left empty in the 24-hour one.
    static const int16_t kSeparator12 = 24;
    static const int16_t kSeparator24 = 5;

    WallTime   mShown;  ///< Reading currently on the display
    ClockStyle mStyle;  ///< Settings the clock is drawn in
};

#endif // MAINVIEW_HPP
