// lib/models/collage_model.dart

class CollageModel {
  final String id;
  final String imageUrl;

  CollageModel({
    required this.id,
    required this.imageUrl,
  });

  factory CollageModel.fromJson(Map<String, dynamic> json) {
    return CollageModel(
      id: json['id'],
      imageUrl: json['image_url'],
    );
  }
}
