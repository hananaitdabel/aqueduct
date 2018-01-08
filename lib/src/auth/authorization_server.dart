import 'dart:async';

import 'package:crypto/crypto.dart';

import '../http/documentable.dart';
import '../utilities/token_generator.dart';
import 'auth.dart';

/// A OAuth 2.0 authorization server.
///
/// An [AuthServer] is an implementation of an OAuth 2.0 authorization server. An authorization server
/// issues, refreshes and revokes access tokens. It also verifies previously issued tokens, as
/// well as client and resource owner credentials.
///
/// [AuthServer]s are typically used in conjunction with [AuthController] and [AuthCodeController].
/// These controllers provide HTTP interfaces to the [AuthServer] for issuing and refreshing tokens.
/// Likewise, [Authorizer]s verify these issued tokens to protect endpoint controllers.
///
/// [AuthServer]s can be customized through their [delegate]. This required property manages persistent storage of authorization
/// objects among other tasks. There are security considerations for [AuthServerDelegate] implementations; prefer to use a tested
/// implementation like `ManagedAuthDelegate` from `package:aqueduct/managed_auth.dart`.
///
/// Usage example with `ManagedAuthDelegate`:
///
///         import 'package:aqueduct/aqueduct.dart';
///         import 'package:aqueduct/managed_auth.dart';
///
///         class User extends ManagedObject<_User> implements _User, ManagedAuthResourceOwner {}
///         class _User extends ManagedAuthenticatable {}
///
///         class Channel extends ApplicationChannel {
///           ManagedContext context;
///           AuthServer authServer;
///
///           @override
///           Future prepare() async {
///             context = createContext();
///
///             final delegate = new ManagedAuthStorage<User>(context);
///             authServer = new AuthServer(delegate);
///           }
///
///           @override
///           Controller get entryPoint {
///             final router = new Router();
///             router
///               .route("/protected")
///               .link(() =>new Authorizer(authServer))
///               .link(() => new ProtectedResourceController());
///
///             router
///               .route("/auth/token")
///               .link(() => new AuthController(authServer));
///
///             return router;
///           }
///         }
///
class AuthServer extends Object with APIDocumentable implements AuthValidator {
  static const String TokenTypeBearer = "bearer";

  /// Creates a new instance of an [AuthServer] with a [delegate].
  ///
  /// [hashFunction] defaults to [sha256].
  AuthServer(this.delegate, {this.hashRounds: 1000, this.hashLength: 32, Hash hashFunction}) :
      this.hashFunction = hashFunction ?? sha256;

  /// The object responsible for carrying out the storage mechanisms of this instance.
  ///
  /// This instance is responsible for storing, fetching and deleting instances of
  /// [AuthToken], [AuthCode] and [AuthClient] by implementing the [AuthServerDelegate] interface.
  ///
  /// It is preferable to use the implementation of [AuthServerDelegate] from 'package:aqueduct/managed_auth.dart'. See
  /// [AuthServer] for more details.
  final AuthServerDelegate delegate;

  /// The number of hashing rounds performed by this instance when validating a password.
  final int hashRounds;

  /// The resulting key length of a password hash when generated by this instance.
  final int hashLength;

  /// The [Hash] function used by the PBKDF2 algorithm to generate password hashes by this instance.
  final Hash hashFunction;

  /// Hashes a [password] with [salt] using PBKDF2 algorithm.
  ///
  /// See [hashRounds], [hashLength] and [hashFunction] for more details. This method
  /// invoke [AuthUtility.generatePasswordHash] with the above inputs.
  String hashPassword(String password, String salt) {
    return AuthUtility.generatePasswordHash(
        password, salt, hashRounds: hashRounds, hashLength: hashLength,
        hashFunction: hashFunction);
  }

  /// Returns a [AuthClient] record for its [clientID].
  ///
  /// A server keeps a cache of known [AuthClient]s. If a client does not exist in the cache,
  /// it will ask its [delegate] via [AuthServerDelegate.fetchClientByID].
  Future<AuthClient> clientForID(String clientID) async {
    return delegate.fetchClientByID(this, clientID);
  }

  /// Revokes a [AuthClient] record.
  ///
  /// Removes cached occurrences of [AuthClient] for [clientID].
  /// Asks [delegate] to remove an [AuthClient] by its ID via [AuthServerDelegate.revokeClientWithID].
  Future revokeClientID(String clientID) async {
    if (clientID == null) {
      throw new AuthServerException(AuthRequestError.invalidClient, null);
    }

    return delegate.revokeClientWithID(this, clientID);
  }

  /// Revokes access for an [Authenticatable].
  ///
  /// This method will ask its [delegate] to revoke all tokens and authorization codes
  /// for a specific [Authenticatable] via [AuthServerDelegate.revokeAuthenticatableWithIdentifier].
  Future revokeAuthenticatableAccessForIdentifier(dynamic identifier) {
    if (identifier == null) {
      return null;
    }

    return delegate.revokeAuthenticatableWithIdentifier(this, identifier);
  }

  /// Authenticates a username and password of an [Authenticatable] and returns an [AuthToken] upon success.
  ///
  /// This method works with this instance's [delegate] to generate and store a new token if all credentials are correct.
  /// If credentials are not correct, it will throw the appropriate [AuthRequestError].
  ///
  /// After [expiration], this token will no longer be valid.
  Future<AuthToken> authenticate(
      String username, String password, String clientID, String clientSecret,
      {Duration expiration: const Duration(hours: 24), List<AuthScope> requestedScopes}) async {
    if (clientID == null) {
      throw new AuthServerException(AuthRequestError.invalidClient, null);
    }

    AuthClient client = await clientForID(clientID);
    if (client == null) {
      throw new AuthServerException(AuthRequestError.invalidClient, null);
    }

    if (username == null || password == null) {
      throw new AuthServerException(AuthRequestError.invalidRequest, client);
    }

    if (client.isPublic) {
      if (!(clientSecret == null || clientSecret == "")) {
        throw new AuthServerException(AuthRequestError.invalidClient, client);
      }
    } else {
      if (clientSecret == null) {
        throw new AuthServerException(AuthRequestError.invalidClient, client);
      }

      if (client.hashedSecret != hashPassword(clientSecret, client.salt)) {
        throw new AuthServerException(AuthRequestError.invalidClient, client);
      }
    }

    var authenticatable =
        await delegate.fetchAuthenticatableByUsername(this, username);
    if (authenticatable == null) {
      throw new AuthServerException(AuthRequestError.invalidGrant, client);
    }

    var dbSalt = authenticatable.salt;
    var dbPassword = authenticatable.hashedPassword;
    var hash = hashPassword(password, dbSalt);
    if (hash != dbPassword) {
      throw new AuthServerException(AuthRequestError.invalidGrant, client);
    }

    List<AuthScope> validScopes = _validatedScopes(client, authenticatable, requestedScopes);
    AuthToken token = _generateToken(
        authenticatable.id, client.id, expiration.inSeconds,
        allowRefresh: !client.isPublic,
        scopes: validScopes);
    await delegate.storeToken(this, token);

    return token;
  }

  /// Returns a [Authorization] for [accessToken].
  ///
  /// This method obtains an [AuthToken] for [accessToken] from [delegate] and then verifies that the token is valid.
  /// If the token is valid, an [Authorization] object is returned. Otherwise, null is returned.
  Future<Authorization> verify(String accessToken, {List<AuthScope> scopesRequired}) async {
    if (accessToken == null) {
      return null;
    }

    AuthToken t = await delegate.fetchTokenByAccessToken(this, accessToken);
    if (t == null || t.isExpired) {
      return null;
    }

    if (scopesRequired != null) {
      var hasAllRequiredScopes = scopesRequired.every((requiredScope) {
        var tokenHasValidScope = t.scopes
            ?.any((tokenScope) => requiredScope.allowsScope(tokenScope));

        return tokenHasValidScope ?? false;
      });

      if (!hasAllRequiredScopes) {
        return null;
      }
    }

    return new Authorization(t.clientID, t.resourceOwnerIdentifier, this, scopes: t.scopes);
  }

  /// Refreshes a valid [AuthToken] instance.
  ///
  /// This method will refresh a [AuthToken] given the [AuthToken]'s [refreshToken] for a given client ID.
  /// This method coordinates with this instance's [delegate] to update the old token with a new access token and issue/expiration dates if successful.
  /// If not successful, it will throw an [AuthRequestError].
  Future<AuthToken> refresh(
      String refreshToken, String clientID, String clientSecret, {List<AuthScope> requestedScopes}) async {
    if (clientID == null) {
      throw new AuthServerException(AuthRequestError.invalidClient, null);
    }

    AuthClient client = await clientForID(clientID);
    if (client == null) {
      throw new AuthServerException(AuthRequestError.invalidClient, null);
    }

    if (refreshToken == null) {
      throw new AuthServerException(AuthRequestError.invalidRequest, client);
    }

    var t = await delegate.fetchTokenByRefreshToken(this, refreshToken);
    if (t == null || t.clientID != clientID) {
      throw new AuthServerException(AuthRequestError.invalidGrant, client);
    }

    if (clientSecret == null) {
      throw new AuthServerException(AuthRequestError.invalidClient, client);
    }

    if (client.hashedSecret != hashPassword(clientSecret, client.salt)) {
      throw new AuthServerException(AuthRequestError.invalidClient, client);
    }

    var updatedScopes = t.scopes;
    if ((requestedScopes?.length ?? 0) != 0) {
      // If we do specify scope
      for (var incomingScope in requestedScopes) {
        var hasExistingScopeOrSuperset = t.scopes
            .any((existingScope) => incomingScope.isSubsetOrEqualTo(existingScope));

        if (!hasExistingScopeOrSuperset) {
          throw new AuthServerException(AuthRequestError.invalidScope, client);
        }

        if (!client.allowsScope(incomingScope)) {
          throw new AuthServerException(AuthRequestError.invalidScope, client);
        }
      }

      updatedScopes = requestedScopes;
    } else if (client.supportsScopes) {
      // Ensure we still have access to same scopes if we didn't specify any
      for (var incomingScope in t.scopes) {
        if (!client.allowsScope(incomingScope)) {
          throw new AuthServerException(AuthRequestError.invalidScope, client);
        }
      }
    }

    var diff = t.expirationDate.difference(t.issueDate);
    var now = new DateTime.now().toUtc();
    var newToken = new AuthToken()
      ..accessToken = randomStringOfLength(32)
      ..issueDate = now
      ..expirationDate = now.add(new Duration(seconds: diff.inSeconds)).toUtc()
      ..refreshToken = t.refreshToken
      ..type = t.type
      ..scopes = updatedScopes
      ..resourceOwnerIdentifier = t.resourceOwnerIdentifier
      ..clientID = t.clientID;

    await delegate.refreshTokenWithAccessToken(this, t.accessToken,
        newToken.accessToken, newToken.issueDate, newToken.expirationDate);

    return newToken;
  }

  /// Creates a one-time use authorization code for a given client ID and user credentials.
  ///
  /// This methods works with this instance's [delegate] to generate and store the authorization code
  /// if the credentials are correct. If they are not correct, it will throw the
  /// appropriate [AuthRequestError].
  Future<AuthCode> authenticateForCode(
      String username, String password, String clientID,
      {int expirationInSeconds: 600, List<AuthScope> requestedScopes}) async {
    if (clientID == null) {
      throw new AuthServerException(AuthRequestError.invalidClient, null);
    }

    AuthClient client = await clientForID(clientID);
    if (client == null) {
      throw new AuthServerException(AuthRequestError.invalidClient, null);
    }

    if (username == null || password == null) {
      throw new AuthServerException(AuthRequestError.invalidRequest, client);
    }

    if (client.redirectURI == null) {
      throw new AuthServerException(
          AuthRequestError.unauthorizedClient, client);
    }

    var authenticatable =
        await delegate.fetchAuthenticatableByUsername(this, username);
    if (authenticatable == null) {
      throw new AuthServerException(AuthRequestError.accessDenied, client);
    }

    var dbSalt = authenticatable.salt;
    var dbPassword = authenticatable.hashedPassword;
    if (hashPassword(password, dbSalt) != dbPassword) {
      throw new AuthServerException(AuthRequestError.accessDenied, client);
    }

    List<AuthScope> validScopes = _validatedScopes(client, authenticatable, requestedScopes);
    AuthCode authCode =
        _generateAuthCode(authenticatable.id, client, expirationInSeconds, scopes: validScopes);
    await delegate.storeAuthCode(this, authCode);
    return authCode;
  }

  /// Exchanges a valid authorization code for an [AuthToken].
  ///
  /// If the authorization code has not expired, has not been used, matches the client ID,
  /// and the client secret is correct, it will return a valid [AuthToken]. Otherwise,
  /// it will throw an appropriate [AuthRequestError].
  Future<AuthToken> exchange(
      String authCodeString, String clientID, String clientSecret,
      {int expirationInSeconds: 3600}) async {
    if (clientID == null) {
      throw new AuthServerException(AuthRequestError.invalidClient, null);
    }

    AuthClient client = await clientForID(clientID);
    if (client == null) {
      throw new AuthServerException(AuthRequestError.invalidClient, null);
    }

    if (authCodeString == null) {
      throw new AuthServerException(AuthRequestError.invalidRequest, null);
    }

    if (clientSecret == null) {
      throw new AuthServerException(AuthRequestError.invalidClient, client);
    }

    if (client.hashedSecret != hashPassword(clientSecret, client.salt)) {
      throw new AuthServerException(AuthRequestError.invalidClient, client);
    }

    AuthCode authCode = await delegate.fetchAuthCodeByCode(this, authCodeString);
    if (authCode == null) {
      throw new AuthServerException(AuthRequestError.invalidGrant, client);
    }

    // check if valid still
    if (authCode.isExpired) {
      await delegate.revokeAuthCodeWithCode(this, authCode.code);
      throw new AuthServerException(AuthRequestError.invalidGrant, client);
    }

    // check that client ids match
    if (authCode.clientID != client.id) {
      throw new AuthServerException(AuthRequestError.invalidGrant, client);
    }

    // check to see if has already been used
    if (authCode.hasBeenExchanged) {
      await delegate.revokeTokenIssuedFromCode(this, authCode);

      throw new AuthServerException(AuthRequestError.invalidGrant, client);
    }
    AuthToken token = _generateToken(
        authCode.resourceOwnerIdentifier, client.id, expirationInSeconds, scopes: authCode.requestedScopes);
    await delegate.storeToken(this, token, issuedFrom: authCode);

    return token;
  }

  //////
  // APIDocumentable overrides
  //////

  static const String _SecuritySchemeClientAuth = "basic.clientAuth";
  static const String _SecuritySchemePassword = "oauth2.password";
  static const String _SecuritySchemeAuthorizationCode = "oauth2.accessCode";

  @override
  Map<String, APISecurityScheme> documentSecuritySchemes(
      PackagePathResolver resolver) {
    var secPassword =
        new APISecurityScheme.oauth2(APISecuritySchemeFlow.password)
          ..description = "OAuth 2.0 Resource Owner Flow";
    var secAccess =
        new APISecurityScheme.oauth2(APISecuritySchemeFlow.authorizationCode)
          ..description = "OAuth 2.0 Authorization Code Flow";
    var basicAccess = new APISecurityScheme.basic()
      ..description = "Client Authentication";

    return {
      _SecuritySchemeClientAuth: basicAccess,
      _SecuritySchemePassword: secPassword,
      _SecuritySchemeAuthorizationCode: secAccess
    };
  }

  /////
  // AuthValidator overrides
  /////

  @override
  FutureOr<Authorization> validate<T>(AuthorizationParser<T> parser, T authorizationData,
      {List<AuthScope> requiredScope}) {
    if (parser is AuthorizationBasicParser) {
      final creds = authorizationData as AuthBasicCredentials;
      return _validateClientCredentials(creds);
    } else if (parser is AuthorizationBearerParser) {
      return verify(authorizationData as String, scopesRequired: requiredScope);
    }

    throw new AuthServerError("Invalid 'parser' for 'AuthServer.validate'. Use 'AuthorizationBasicParser' or 'AuthorizationBearerHeader'.");
  }

  Future<Authorization> _validateClientCredentials(
      AuthBasicCredentials credentials) async {
    var username = credentials.username;
    var password = credentials.password;

    var client = await clientForID(username);

    if (client == null) {
      return null;
    }

    if (client.hashedSecret == null) {
      if (password == "") {
        return new Authorization(client.id, null, this, credentials: credentials);
      }

      return null;
    }

    if (client.hashedSecret != hashPassword(password, client.salt)) {
      return null;
    }

    return new Authorization(client.id, null, this, credentials: credentials);
  }


  @override
  List<APISecurityRequirement> requirementsForStrategy(AuthorizationParser strategy) {
    if (strategy is AuthorizationBasicParser) {
      return [new APISecurityRequirement()..name = _SecuritySchemeClientAuth];
    } else if (strategy is AuthorizationBearerParser) {
      return [
        new APISecurityRequirement()..name = _SecuritySchemeAuthorizationCode,
        new APISecurityRequirement()..name = _SecuritySchemePassword
      ];
    }

    return [];
  }

  List<AuthScope> _validatedScopes(AuthClient client, Authenticatable authenticatable, List<AuthScope> requestedScopes) {
    List<AuthScope> validScopes;
    if (client.supportsScopes) {
      if ((requestedScopes?.length ?? 0) == 0) {
        throw new AuthServerException(AuthRequestError.invalidScope, client);
      }

      validScopes = requestedScopes
          .where((incomingScope) => client.allowsScope(incomingScope))
          .toList();

      if (validScopes.length == 0) {
        throw new AuthServerException(AuthRequestError.invalidScope, client);
      }

      var validScopesForAuthenticatable = delegate.allowedScopesForAuthenticatable(authenticatable);
      if (!identical(validScopesForAuthenticatable, AuthScope.Any)) {
        validScopes = validScopes
            .where((clientAllowedScope) =>
              validScopesForAuthenticatable.any((userScope) =>
                  userScope.allowsScope(clientAllowedScope)))
            .toList();

        if (validScopes.length == 0) {
          throw new AuthServerException(AuthRequestError.invalidScope, client);
        }
      }
    }

    return validScopes;
  }

  AuthToken _generateToken(
      dynamic ownerID, String clientID, int expirationInSeconds,
      {bool allowRefresh: true, List<AuthScope> scopes}) {
    var now = new DateTime.now().toUtc();
    AuthToken token = new AuthToken()
      ..accessToken = randomStringOfLength(32)
      ..issueDate = now
      ..expirationDate = now.add(new Duration(seconds: expirationInSeconds))
      ..type = TokenTypeBearer
      ..resourceOwnerIdentifier = ownerID
      ..scopes = scopes
      ..clientID = clientID;

    if (allowRefresh) {
      token.refreshToken = randomStringOfLength(32);
    }

    return token;
  }

  AuthCode _generateAuthCode(
      dynamic ownerID, AuthClient client, int expirationInSeconds, {List<AuthScope> scopes}) {
    var now = new DateTime.now().toUtc();
    return new AuthCode()
      ..code = randomStringOfLength(32)
      ..clientID = client.id
      ..resourceOwnerIdentifier = ownerID
      ..issueDate = now
      ..requestedScopes = scopes
      ..expirationDate = now.add(new Duration(seconds: expirationInSeconds));
  }
}

class AuthServerError extends Error {
  AuthServerError(this.message);
  String message;

  @override
  String toString() {
    return "AuthServerError: $message";
  }

}