package service

import "context"

const sha256HexLength = 64

// InvalidateAuthCacheByKey 清除指定 API Key 的认证缓存
func (s *APIKeyService) InvalidateAuthCacheByKey(ctx context.Context, key string) {
	if key == "" {
		return
	}
	cacheKey := s.authCacheKey(key)
	s.deleteAuthCache(ctx, cacheKey)
}

// InvalidateAuthCacheByHash clears an authentication cache entry when the
// caller already has the persisted SHA-256 credential hash.  Keeping this
// path separate avoids materializing the legacy plaintext key solely for
// cache invalidation.
func (s *APIKeyService) InvalidateAuthCacheByHash(ctx context.Context, keyHash string) {
	if len(keyHash) != sha256HexLength {
		return
	}
	s.deleteAuthCache(ctx, keyHash)
}

// InvalidateAuthCacheByUserID 清除用户相关的 API Key 认证缓存
func (s *APIKeyService) InvalidateAuthCacheByUserID(ctx context.Context, userID int64) {
	if userID <= 0 {
		return
	}
	if repo, ok := s.apiKeyRepo.(APIKeyHashRepository); ok {
		if hashes, err := repo.ListKeyHashesByUserID(ctx, userID); err == nil {
			s.deleteAuthCacheByHashes(ctx, hashes)
			return
		}
	}
	keys, err := s.apiKeyRepo.ListKeysByUserID(ctx, userID)
	if err != nil {
		return
	}
	s.deleteAuthCacheByKeys(ctx, keys)
}

// InvalidateAuthCacheByGroupID 清除分组相关的 API Key 认证缓存
func (s *APIKeyService) InvalidateAuthCacheByGroupID(ctx context.Context, groupID int64) {
	if groupID <= 0 {
		return
	}
	if repo, ok := s.apiKeyRepo.(APIKeyHashRepository); ok {
		if hashes, err := repo.ListKeyHashesByGroupID(ctx, groupID); err == nil {
			s.deleteAuthCacheByHashes(ctx, hashes)
			return
		}
	}
	keys, err := s.apiKeyRepo.ListKeysByGroupID(ctx, groupID)
	if err != nil {
		return
	}
	s.deleteAuthCacheByKeys(ctx, keys)
}

func (s *APIKeyService) deleteAuthCacheByKeys(ctx context.Context, keys []string) {
	if len(keys) == 0 {
		return
	}
	for _, key := range keys {
		if key == "" {
			continue
		}
		s.deleteAuthCache(ctx, s.authCacheKey(key))
	}
}

func (s *APIKeyService) deleteAuthCacheByHashes(ctx context.Context, hashes []string) {
	if len(hashes) == 0 {
		return
	}
	for _, keyHash := range hashes {
		s.InvalidateAuthCacheByHash(ctx, keyHash)
	}
}

// invalidateAuthCacheByHashes uses the optional hash-only invalidator when
// available. It returns false when the supplied adapter predates the rolling
// hash capability so callers can retain their legacy fallback path.
func invalidateAuthCacheByHashes(ctx context.Context, invalidator APIKeyAuthCacheInvalidator, hashes []string) bool {
	hashInvalidator, ok := invalidator.(APIKeyHashCacheInvalidator)
	if !ok {
		return false
	}
	for _, keyHash := range hashes {
		hashInvalidator.InvalidateAuthCacheByHash(ctx, keyHash)
	}
	return true
}
