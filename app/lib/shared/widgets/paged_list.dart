import 'package:flutter/material.dart';

import '../../core/widgets/widgets.dart';
import '../models/models.dart';

/// Paginated list with loading / error / empty / pull-to-refresh / "load more". Bump [reloadToken] to force a reload.
class PagedList<T> extends StatefulWidget {
  const PagedList({super.key, required this.load, required this.itemBuilder, required this.empty, this.reloadToken = 0, this.header});
  final Future<Paged<T>> Function(int page) load;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final Widget empty;
  final int reloadToken;
  final Widget? header;
  @override
  State<PagedList<T>> createState() => _PagedListState<T>();
}

class _PagedListState<T> extends State<PagedList<T>> {
  final List<T> _items = [];
  int _page = 0;
  bool _loading = true, _more = false, _loadingMore = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _first();
  }

  @override
  void didUpdateWidget(covariant PagedList<T> old) {
    super.didUpdateWidget(old);
    if (old.reloadToken != widget.reloadToken) _first();
  }

  Future<void> _first() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await widget.load(1);
      _items
        ..clear()
        ..addAll(p.items);
      _page = 1;
      _more = p.hasMore;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _next() async {
    setState(() => _loadingMore = true);
    try {
      final p = await widget.load(_page + 1);
      _items.addAll(p.items);
      _page += 1;
      _more = p.hasMore;
    } catch (e) {
      if (mounted) toast(context, 'Could not load more: $e', error: true);
    }
    if (mounted) setState(() => _loadingMore = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _items.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _items.isEmpty) return ErrorState(_error!, onRetry: _first);
    if (_items.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: [if (widget.header != null) widget.header!, widget.empty]);
    }
    return RefreshIndicator(
      onRefresh: _first,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.header != null) widget.header!,
          for (final i in _items) Padding(padding: const EdgeInsets.only(bottom: 10), child: widget.itemBuilder(context, i)),
          if (_more)
            Center(child: Padding(padding: const EdgeInsets.all(8), child: _loadingMore ? const CircularProgressIndicator() : OutlinedButton(onPressed: _next, child: const Text('Load more')))),
        ],
      ),
    );
  }
}
