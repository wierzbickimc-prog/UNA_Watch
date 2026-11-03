/**
 ******************************************************************************
 * @file    RouteListScreen.cpp
 * @brief   Choose the route for the next run (see the header).
 ******************************************************************************
 */

#include "gui/screens/RouteListScreen.hpp"
#include "gui/screens/ScreenManager.hpp"
#include "gui/theme/Theme.hpp"
#include "gui/WorkoutUi.hpp"

#include <cstring>

namespace Color = SDK::GUI::Color;
using Style = WheelMenu::Item::Style;
using F     = Theme::Font;

namespace
{
/// A label centred on (120, @p cy).
lv_obj_t* centred(lv_obj_t* parent, F font, const char* text, int32_t cy, uint32_t color)
{
    lv_obj_t* l = Theme::label(parent, font, text, 0, 0, LV_SIZE_CONTENT, LV_TEXT_ALIGN_LEFT, color);
    lv_obj_align(l, LV_ALIGN_CENTER, 0, cy - SDK::LVGL::kCy);
    return l;
}
} // namespace

RouteListScreen::RouteListScreen(Model& model)
    : Screen(model)
{
}

RouteListScreen::~RouteListScreen() = default;

void RouteListScreen::build()
{
    mMenuBox = Theme::container(mRoot, 0, 0, 240, 240);
    mButtons = std::make_unique<Widgets::Buttons>(mRoot);
    mButtons->set(Widgets::Buttons::NONE, Widgets::Buttons::NONE,
                  Widgets::Buttons::AMBER, Widgets::Buttons::WHITE);
    mTitle = std::make_unique<Widgets::Title>(mRoot, "ROUTES");

    // Shown instead of the list when there are no route files.
    mEmpty[0] = centred(mRoot, F::SemiBold25, "No routes", 104, Color::WHITE);
    mEmpty[1] = centred(mRoot, F::Medium18, "Copy routes to the", 142, Color::GRAY);
    mEmpty[2] = centred(mRoot, F::Medium18, "Routes folder", 165, Color::GRAY);
}

void RouteListScreen::onShow()
{
    mModel.resetIdleTimer();
    setList();
}

void RouteListScreen::onRouteList()
{
    setList();
}

void RouteListScreen::setList()
{
    // The wheel is built for a fixed number of rows: start it afresh.
    mMenu.reset();
    lv_obj_clean(mMenuBox);
    mItems.reset();
    mText.reset();

    const RouteCatalog* catalog = mModel.getRouteCatalog();
    const size_t routes = catalog != nullptr ? catalog->size() : 0;
    const bool empty = routes == 0;
    Theme::setHidden(mMenuBox, empty);
    for (lv_obj_t* l : mEmpty) {
        Theme::setHidden(l, !empty);
    }
    mButtons->setR1(empty ? Widgets::Buttons::NONE : Widgets::Buttons::AMBER);
    if (empty) {
        mRows = 0;
        return;
    }

    mRows  = static_cast<uint16_t>(routes + 1);
    mItems = std::make_unique<WheelMenu::Item[]>(mRows);
    mText  = std::make_unique<RowText[]>(mRows);

    const uint16_t selectedRow = static_cast<uint16_t>(catalog->selected() + 1);
    for (uint16_t row = 0; row < mRows; ++row) {
        RowText& text = mText[row];
        const char* name = row == 0 ? "No route" : catalog->name(row - 1);
        std::strncpy(text.text, name, sizeof(text.text) - 1);
        text.text[sizeof(text.text) - 1] = '\0';
        std::memcpy(text.itemText, text.text, sizeof(text.itemText));
        WorkoutUi::fitWidth(text.text, sizeof(text.text), Theme::font(F::SemiBold25), 200);
        WorkoutUi::fitWidth(text.itemText, sizeof(text.itemText), Theme::font(F::Medium18), 190);

        mItems[row] = { Style::Tip, text.text, text.itemText, Theme::font(F::SemiBold25),
                        row == selectedRow ? "Selected" : "", Color::TEAL };
        mItems[row].itemTip = "";
    }

    mMenu = std::make_unique<WheelMenu>(mMenuBox, mItems.get(), mRows);
    mMenu->setCircular(mRows > 1);
    mMenu->select(selectedRow);
}

void RouteListScreen::onKey(uint8_t code)
{
    namespace Btn = SDK::GUI::Button;
    switch (code) {
        case Btn::L1:
            if (mMenu) {
                mMenu->prev();
            }
            break;
        case Btn::L2:
            if (mMenu) {
                mMenu->next();
            }
            break;
        case Btn::R1:
            if (mMenu) {
                mModel.selectRoute(static_cast<int16_t>(mMenu->selected()) - 1);
                ScreenManager::instance().goTo(ScreenId::Main);
            }
            break;
        case Btn::R2:
            ScreenManager::instance().goTo(ScreenId::Main);
            break;
        default:
            break;
    }
}
