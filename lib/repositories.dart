import 'api.dart';
import 'models.dart';

class AuthRepository {
  AuthRepository(this.api);
  final LocalSpotApi api;

  Future<Map<String, dynamic>> login({required String email, required String password}) async {
    final data = await api.post('/auth/login', {'email': email, 'password': password});
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String password,
    required AppRole role,
  }) async {
    final data = await api.post('/auth/register', {
      'name': name,
      'email': email,
      'password': password,
      'role': role.name,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> me() async {
    final data = await api.get('/me');
    return Map<String, dynamic>.from(data as Map);
  }
}

class CatalogRepository {
  CatalogRepository(this.api);
  final LocalSpotApi api;

  Future<Map<String, dynamic>> catalog() async {
    final data = await api.get('/catalog');
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> searchListings(Map<String, String> query) {
    return api.getEnvelope('/search', query);
  }
}
