import 'package:flutter/material.dart';

import '../../features/home/presentation/pages/home_page.dart';
import '../../features/home/presentation/pages/splash_page.dart';
import '../../features/auth/presentation/pages/login_page.dart';
import '../../features/quick_sale/presentation/pages/quick_sale_page.dart';
import '../../features/sales/presentation/pages/billiard_tables_page.dart';
import '../../features/sales/presentation/pages/create_promo_page.dart';
import '../../features/inventory/presentation/pages/inventory_page.dart';
import '../../features/purchases/presentation/pages/purchases_page.dart';
import '../../features/stats/presentation/pages/stats_page.dart';
import '../../features/stats/presentation/pages/sales_history_page.dart';
import '../../features/players/presentation/pages/players_list_page.dart';
import '../../features/players/presentation/pages/player_detail_page.dart';
import '../../features/players/presentation/pages/player_comparison_page.dart';
import '../../features/players/presentation/pages/record_match_page.dart';
import '../../features/players/domain/entities/player_stats.dart';
import '../../features/dine_in/presentation/pages/dine_in_page.dart';
import '../../features/special_client/presentation/pages/special_client_page.dart';
import '../../features/config/presentation/pages/initial_setup_page.dart';
import '../../features/config/presentation/pages/config_page.dart';
import '../../features/games/presentation/pages/games_page.dart';
import '../../features/tournaments/presentation/pages/tournaments_page.dart';
import '../../features/personal_stats/presentation/pages/personal_stats_page.dart';
import 'app_routes.dart';

class AppRouter {
  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.splash:
        return MaterialPageRoute(builder: (_) => const SplashPage());
      case AppRoutes.login:
        return MaterialPageRoute(builder: (_) => const LoginPage());
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
      case AppRoutes.stats:
        return MaterialPageRoute(builder: (_) => const StatsPage());
      case AppRoutes.salesHistory:
        return MaterialPageRoute(builder: (_) => const SalesHistoryPage());
      case AppRoutes.players:
        return MaterialPageRoute(builder: (_) => const PlayersListPage());
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
      case AppRoutes.games:
        return MaterialPageRoute(builder: (_) => const GamesPage());
      case AppRoutes.tournaments:
        return MaterialPageRoute(builder: (_) => const TournamentsPage());
      case AppRoutes.personalStats:
        return MaterialPageRoute(builder: (_) => const PersonalStatsPage());
      default:
        return MaterialPageRoute(builder: (_) => const HomePage());
    }
  }
}
