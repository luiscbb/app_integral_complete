import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/home/presentation/pages/home_page.dart';
import '../../features/home/presentation/pages/splash_page.dart';
import '../../features/auth/presentation/pages/login_page.dart';
import '../../features/quick_sale/presentation/pages/quick_sale_page.dart';
import '../../features/auth/presentation/pages/staff_route_gate.dart';
import '../../features/auth/domain/staff_access.dart';
import '../../features/sales/presentation/pages/billiard_tables_page.dart';
import '../../features/sales/presentation/pages/create_promo_page.dart';
import '../../features/inventory/presentation/pages/inventory_page.dart';
import '../../features/purchases/presentation/pages/purchases_page.dart';
import '../../features/reports/presentation/pages/reports_page.dart';
import '../../features/reports/presentation/pages/sales_history_page.dart';
import '../../features/players/presentation/pages/players_hub_page.dart';
import '../../features/players/presentation/pages/players_list_page.dart';
import '../../features/players/presentation/pages/player_detail_page.dart';
import '../../features/players/presentation/pages/player_comparison_page.dart';
import '../../features/players/presentation/pages/player_access_pages.dart';
import '../../features/players/presentation/pages/record_match_page.dart';
import '../../features/players/domain/entities/player_stats.dart';
import '../../features/dine_in/presentation/pages/dine_in_page.dart';
import '../../features/special_client/presentation/pages/special_client_page.dart';
import '../../features/config/presentation/pages/initial_setup_page.dart';
import '../../features/config/presentation/pages/config_page.dart';
import '../../features/games/presentation/pages/games_page.dart';
import '../../features/auth/presentation/pages/reset_password_page.dart';
import '../../features/tournaments/presentation/pages/tournaments_page.dart';
import '../../features/personal_stats/presentation/pages/personal_stats_page.dart';
import 'app_routes.dart';

class AppRouter {
  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    return generateRoute(settings, enableStaffForIntegration: staffPilotEnabled);
  }

  static Route<dynamic> generateRoute(
    RouteSettings settings, {
    bool enableStaffForIntegration = false,
  }) {
    final staff = Supabase.instance.client.auth.currentUser
        ?.appMetadata['account_type'] == 'staff';
    if (settings.name == AppRoutes.staffPortal ||
        (staff && settings.name != AppRoutes.login && settings.name != AppRoutes.splash)) {
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => StaffRouteGate(
          routeName: settings.name,
          enableForIntegration: enableStaffForIntegration,
        ),
      );
    }
    switch (settings.name) {
      case AppRoutes.splash:
        return MaterialPageRoute(builder: (_) => SplashPage(
          enableStaffForIntegration: enableStaffForIntegration,
        ));
      case AppRoutes.login:
        return MaterialPageRoute(builder: (_) => LoginPage(
          enableStaffForIntegration: enableStaffForIntegration,
        ));
      case AppRoutes.initialSetup:
        return MaterialPageRoute(builder: (_) => const InitialSetupPage());
      case AppRoutes.home:
        return MaterialPageRoute(builder: (_) => const HomePage());
      case AppRoutes.quickSale:
        return MaterialPageRoute(builder: (_) => const QuickSalePage());
      case AppRoutes.billiardTables:
        return MaterialPageRoute(builder: (_) => const BilliardTablesPage());
      case AppRoutes.inventory:
        return MaterialPageRoute(builder: (_) => const InventoryPage());
      case AppRoutes.createPromo:
        return MaterialPageRoute(builder: (_) => const CreatePromoPage());
      case AppRoutes.purchases:
        return MaterialPageRoute(builder: (_) => const PurchasesPage());
      case AppRoutes.reports:
        return MaterialPageRoute(builder: (_) => const ReportsPage());
      case AppRoutes.salesHistory:
        return MaterialPageRoute(builder: (_) => const SalesHistoryPage());
      case AppRoutes.players:
        return MaterialPageRoute(builder: (_) => const PlayersListPage());
      case AppRoutes.playersHub:
        return MaterialPageRoute(builder: (_) => const PlayersHubPage());
      case AppRoutes.playerDetail:
        final args = settings.arguments;
        if (args is PlayerEntity) {
          return MaterialPageRoute(builder: (_) => PlayerDetailPage(player: args));
        }
        return MaterialPageRoute(builder: (_) => const PlayersListPage());
      case AppRoutes.playerComparison:
        return MaterialPageRoute(builder: (_) => const PlayerComparisonPage());
      case AppRoutes.recordMatch:
        return MaterialPageRoute(builder: (_) => const RecordMatchPage());
      case AppRoutes.dineIn:
        return MaterialPageRoute(builder: (_) => const DineInPage());
      case AppRoutes.specialClient:
        return MaterialPageRoute(builder: (_) => const SpecialClientPage());
      case AppRoutes.config:
        return MaterialPageRoute(builder: (_) => const ConfigPage());
      case AppRoutes.resetPassword:
        return MaterialPageRoute(builder: (_) => const ResetPasswordPage());
      case AppRoutes.games:
        return MaterialPageRoute(builder: (_) => const GamesPage());
      case AppRoutes.tournaments:
        return MaterialPageRoute(builder: (_) => const TournamentsPage());
      case AppRoutes.personalStats:
        return MaterialPageRoute(builder: (_) => const PersonalStatsPage());
      case AppRoutes.playerPortal:
        final args = settings.arguments;
        if (args is PlayerEntity) {
          return MaterialPageRoute(
            builder: (_) => PlayerPortalPage(player: args),
          );
        }
        return MaterialPageRoute(builder: (_) => const SplashPage());
      case AppRoutes.managerPortal:
        return MaterialPageRoute(builder: (_) => const ManagerPortalPage());
      case AppRoutes.changeTemporaryPassword:
        return MaterialPageRoute(
          builder: (_) => const ChangeTemporaryPasswordPage(),
        );
      default:
        return MaterialPageRoute(builder: (_) => const HomePage());
    }
  }
}
