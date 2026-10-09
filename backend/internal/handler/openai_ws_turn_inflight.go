package handler

import (
	"context"
	"sync"

	"github.com/Wei-Shaw/sub2api/internal/service"
)

type openAIWSTurnInflightRequest struct {
	model   string
	payload []byte
}

type openAIWSTurnInflightReservation struct {
	ctx  context.Context
	done func()
}

type openAIWSTurnInflightState struct {
	mu           sync.Mutex
	requests     map[int]openAIWSTurnInflightRequest
	reservations map[int]openAIWSTurnInflightReservation
}

func (s *openAIWSTurnInflightState) setRequest(turn int, model string, payload []byte) {
	if turn <= 1 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.requests == nil {
		s.requests = make(map[int]openAIWSTurnInflightRequest)
	}
	s.requests[turn] = openAIWSTurnInflightRequest{model: model, payload: append([]byte(nil), payload...)}
}

func (s *openAIWSTurnInflightState) reserve(
	ctx context.Context,
	turn int,
	billing *service.BillingCacheService,
	estimator inflightReservationEstimator,
	apiKey *service.APIKey,
	subscription *service.UserSubscription,
) error {
	if turn <= 1 {
		return nil
	}
	s.mu.Lock()
	if _, exists := s.reservations[turn]; exists {
		s.mu.Unlock()
		return nil
	}
	request, ok := s.requests[turn]
	s.mu.Unlock()
	if !ok {
		return nil
	}

	turnCtx, done, err := reserveInflightBalanceCtx(ctx, billing, estimator, apiKey, subscription, tokenInflightEstimate(request.model, request.payload))
	if err != nil {
		return err
	}
	s.mu.Lock()
	if s.reservations == nil {
		s.reservations = make(map[int]openAIWSTurnInflightReservation)
	}
	if _, exists := s.reservations[turn]; exists {
		s.mu.Unlock()
		done()
		return nil
	}
	s.reservations[turn] = openAIWSTurnInflightReservation{ctx: turnCtx, done: done}
	s.mu.Unlock()
	return nil
}

func (s *openAIWSTurnInflightState) take(turn int, fallback context.Context) (context.Context, func()) {
	if turn <= 1 {
		return fallback, inflightNoop
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.requests, turn)
	reservation, ok := s.reservations[turn]
	delete(s.reservations, turn)
	if !ok {
		return fallback, inflightNoop
	}
	return reservation.ctx, reservation.done
}
