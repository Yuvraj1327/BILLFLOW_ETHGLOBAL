typedef Json = Map<String, dynamic>;

Json asJson(dynamic v) => Map<String, dynamic>.from(v as Map);
List<Json> asJsonList(dynamic v) => (v as List).map((e) => asJson(e)).toList();

extension JsonX on Json {
  String str(String k) => (this[k] ?? '').toString();
  String? strN(String k) => this[k] == null ? null : this[k].toString();
  int integer(String k) => this[k] is int ? this[k] as int : int.tryParse('${this[k]}') ?? 0;
  int? integerN(String k) => this[k] == null ? null : integer(k);
  bool flag(String k) => this[k] == true;
  double dbl(String k) => this[k] is num ? (this[k] as num).toDouble() : double.tryParse('${this[k]}') ?? 0;
  DateTime? date(String k) => this[k] == null ? null : DateTime.tryParse('${this[k]}')?.toLocal();
  Json? obj(String k) => this[k] is Map ? asJson(this[k]) : null;
}
