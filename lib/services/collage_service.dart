// lib/services/collage_service.dart

import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/collage_model.dart';

class CollageService {
  final _client = Supabase.instance.client;

  Future<List<CollageModel>> fetchCollages() async {
    final res = await _client
        .from('collages')
        .select()
        .order('created_at', ascending: false);

    return (res as List)
        .map((e) => CollageModel.fromJson(e))
        .toList();
  }

  Future<void> deleteCollage(CollageModel collage) async {
    await _client.from('collages').delete().eq('id', collage.id);

    final path = collage.imageUrl.split('/collages/').last;
    await _client.storage.from('collages').remove([path]);
  }
}
