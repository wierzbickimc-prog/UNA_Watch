/**
 ******************************************************************************
 * @file    RouteListScreen.hpp
 * @brief   Choose the route for the next run: the routes in the Routes folder,
 *          after "No route". R1 selects, R2 goes back.
 ******************************************************************************
 */

#ifndef ROUTE_LIST_SCREEN_HPP
#define ROUTE_LIST_SCREEN_HPP

#include <memory>

#include "gui/screens/Screen.hpp"
#include "gui/widgets/Widgets.hpp"
#include "gui/widgets/WheelMenu.hpp"
#include "RouteCatalog.hpp"

class RouteListScreen : public Screen
{
public:
    explicit RouteListScreen(Model& model);
    ~RouteListScreen() override;

    // Screen
    void onShow() override;
    void onKey(uint8_t code) override;

    // ModelListener
    void onRouteList() override;

protected:
    void build() override;

private:
    static constexpr uint16_t kMaxRows = RouteCatalog::kMaxRoutes + 1;  ///< + No route

    struct RowText {
        char text[RouteCatalog::kNameBytes];
        char itemText[RouteCatalog::kNameBytes];
    };

    void setList();

    uint16_t mRows = 0;
    std::unique_ptr<WheelMenu::Item[]> mItems;
    std::unique_ptr<RowText[]>         mText;

    lv_obj_t* mMenuBox = nullptr;  ///< Holds the wheel, hidden when there are no routes
    lv_obj_t* mEmpty[3] = {};
    std::unique_ptr<WheelMenu>        mMenu;
    std::unique_ptr<Widgets::Buttons> mButtons;
    std::unique_ptr<Widgets::Title>   mTitle;
};

#endif // ROUTE_LIST_SCREEN_HPP
