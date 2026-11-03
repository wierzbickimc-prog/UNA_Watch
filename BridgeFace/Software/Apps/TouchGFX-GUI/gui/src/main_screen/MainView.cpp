#include <gui/main_screen/MainView.hpp>
#include <touchgfx/Color.hpp>

/// The face is square and the clock is centred on it.
static const int16_t kFaceWidth = 240;

MainView::MainView()
    : mShown{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }  // nothing on screen yet, so the first reading draws
    , mStyle{ false, false }
{

}

void MainView::setupScreen()
{
    MainViewBase::setupScreen();

    touchgfx::Drawable *const unused[] = {
        &battery, &dividerLeft, &dividerRight, &stepsIcon, &activityIcon, &hrIcon,
        &stepsValue, &stepsUnit, &activityValue, &activityUnit, &hrValue, &hrUnit,
    };
    for (touchgfx::Drawable *widget : unused) {
        widget->setVisible(false);
    }

    const touchgfx::colortype white = touchgfx::Color::getColorFromRGB(255, 255, 255);
    hourText.setColor(white);
    colonText.setColor(white);
    minuteText.setColor(white);
    dateText.setColor(white);

    // The Designer leaves every wildcard on its placeholder, so the real
    // readings go up before the first frame rather than after the first tick.
    mStyle = presenter->clockStyle();

    setTime(presenter->currentTime());
    setBatteryLevel(presenter->batteryLevel());
}

void MainView::tearDownScreen()
{
    MainViewBase::tearDownScreen();
}

void MainView::place(touchgfx::TextArea &area, int16_t x, int16_t width)
{
    // Repaint where it was, then where it is: setPosition() invalidates
    // neither, and a widget that has moved has left a hole behind it.
    area.invalidate();
    area.setPosition(x, kClockY, width, kClockHeight);
    area.invalidate();
}

void MainView::layoutClock()
{
    const int16_t hourWidth   = static_cast<int16_t>(hourText.getTextWidth());
    const int16_t minuteWidth = static_cast<int16_t>(minuteText.getTextWidth());
    const int16_t sepWidth    = mStyle.is12h ? kSeparator12 : kSeparator24;

    const int16_t total = static_cast<int16_t>(hourWidth + sepWidth + minuteWidth);

    int16_t x = static_cast<int16_t>((kFaceWidth - total) / 2);

    place(hourText, x, hourWidth);
    x = static_cast<int16_t>(x + hourWidth);

    // The colon is centred in the separator, which is why it is given the
    // separator's width rather than its own.
    place(colonText, x, sepWidth);
    x = static_cast<int16_t>(x + sepWidth);

    place(minuteText, x, minuteWidth);

    // invalidate(), not invalidateContent(): the latter does nothing on a
    // widget that has just been hidden, which is exactly when the area it used
    // to cover has to be repainted.
    colonText.setVisible(mStyle.is12h);
    colonText.invalidate();
}

void MainView::updateClockText()
{
    if (mStyle.is12h) {
        const uint8_t hour12 = (mShown.hour % 12u) == 0u ? 12u : (mShown.hour % 12u);
        Unicode::snprintf(hourTextBuffer, HOURTEXT_SIZE, "%u",
                          static_cast<unsigned>(hour12));
    } else {
        Unicode::snprintf(hourTextBuffer, HOURTEXT_SIZE, "%02u",
                          static_cast<unsigned>(mShown.hour));
    }

    Unicode::snprintf(minuteTextBuffer, MINUTETEXT_SIZE, "%02u",
                      static_cast<unsigned>(mShown.minute));
}

void MainView::setTime(const WallTime &time)
{
    if (time == mShown) {
        return;
    }

    mShown = time;

    updateClockText();
    layoutClock();
}

void MainView::setClockStyle(const ClockStyle &style)
{
    if (style == mStyle) {
        return;
    }

    mStyle = style;

    updateClockText();
    layoutClock();
}

void MainView::setBatteryLevel(uint8_t level)
{
    dateText.invalidate();
    Unicode::snprintf(dateTextBuffer, DATETEXT_SIZE, "%u", static_cast<unsigned>(level));

    // Ends where the photo's percent sign starts, however many digits it has.
    const int16_t width = static_cast<int16_t>(dateText.getTextWidth());
    dateText.setPosition(static_cast<int16_t>(kPercentX - width), kBatteryY, width, kBatteryHeight);
    dateText.invalidate();
}
