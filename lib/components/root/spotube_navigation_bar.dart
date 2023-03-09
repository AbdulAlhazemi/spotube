import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:spotube/collections/side_bar_tiles.dart';
import 'package:spotube/components/root/sidebar.dart';
import 'package:spotube/hooks/use_breakpoints.dart';
import 'package:spotube/provider/downloader_provider.dart';
import 'package:spotube/provider/user_preferences_provider.dart';

class SpotubeNavigationBar extends HookConsumerWidget {
  final int selectedIndex;
  final void Function(int) onSelectedIndexChanged;

  const SpotubeNavigationBar({
    required this.selectedIndex,
    required this.onSelectedIndexChanged,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, ref) {
    final downloadCount = ref.watch(
      downloaderProvider.select((s) => s.currentlyRunning),
    );
    final breakpoint = useBreakpoints();
    final layoutMode =
        ref.watch(userPreferencesProvider.select((s) => s.layoutMode));

    final insideSelectedIndex = useState<int>(selectedIndex);

    useEffect(() {
      insideSelectedIndex.value = selectedIndex;
      return null;
    }, [selectedIndex]);

    if (layoutMode == LayoutMode.extended ||
        (breakpoint.isMoreThan(Breakpoints.sm) &&
            layoutMode == LayoutMode.adaptive)) return const SizedBox();
    return BottomNavigationBar(
      items: [
        ...navbarTileList.map(
          (e) {
            return BottomNavigationBarItem(
              icon: Badge(
                backgroundColor: Theme.of(context).primaryColor,
                isLabelVisible: e.title == "Library" && downloadCount > 0,
                label: Text(
                  downloadCount.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                  ),
                ),
                child: Icon(e.icon),
              ),
              label: e.title,
            );
          },
        ),
      ],
      currentIndex: insideSelectedIndex.value,
      onTap: (i) {
        insideSelectedIndex.value = i;
        if (navbarTileList[i].title == "Settings") {
          Sidebar.goToSettings(context);
          return;
        }
        onSelectedIndexChanged(i);
      },
    );
  }
}
