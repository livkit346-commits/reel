package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

// JWT Header (alg: HS256, typ: JWT) base64URL encoded
const jwtHeaderB64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

// Hashing: Generates a 16-byte cryptographically secure random salt
func generateSalt() ([]byte, error) {
	salt := make([]byte, 16)
	_, err := rand.Read(salt)
	if err != nil {
		return nil, err
	}
	return salt, nil
}

// Hashing: Stretched HMAC-SHA512 over 10,000 iterations
func hashPassword(password string, salt []byte) []byte {
	h := hmac.New(sha512.New, salt)
	h.Write([]byte(password))
	val := h.Sum(nil)
	for i := 0; i < 9999; i++ {
		h.Reset()
		h.Write(val)
		val = h.Sum(nil)
	}
	return val
}

// JWT: Generate an access token signed with the shared secret key
func GenerateJWT(userID, email string, secret []byte) (string, error) {
	now := time.Now()
	claims := map[string]interface{}{
		"sub":   userID,
		"email": email,
		"role":  "authenticated",
		"aud":   "authenticated",
		"iat":   now.Unix(),
		"exp":   now.Add(1 * time.Hour).Unix(),
	}

	claimsBytes, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}

	payloadB64 := base64.RawURLEncoding.EncodeToString(claimsBytes)
	signingString := jwtHeaderB64 + "." + payloadB64

	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(signingString))
	signatureB64 := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))

	return signingString + "." + signatureB64, nil
}

// JWT: Parse and verify access token locally
func ValidateJWT(tokenString string, secret []byte) (map[string]interface{}, error) {
	parts := strings.Split(tokenString, ".")
	if len(parts) != 3 {
		return nil, errors.New("invalid token format")
	}

	signingString := parts[0] + "." + parts[1]
	signatureBytes, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, errors.New("invalid signature encoding")
	}

	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(signingString))
	expectedSignature := mac.Sum(nil)

	if !hmac.Equal(signatureBytes, expectedSignature) {
		return nil, errors.New("signature verification failed")
	}

	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errors.New("invalid payload encoding")
	}

	var claims map[string]interface{}
	if err := json.Unmarshal(payloadBytes, &claims); err != nil {
		return nil, err
	}

	// Verify expiration claim
	if expVal, ok := claims["exp"]; ok {
		var exp int64
		switch v := expVal.(type) {
		case float64:
			exp = int64(v)
		case int64:
			exp = v
		default:
			return nil, errors.New("invalid expiration claim type")
		}

		if time.Now().Unix() > exp {
			return nil, errors.New("token expired")
		}
	} else {
		return nil, errors.New("missing expiration claim")
	}

	return claims, nil
}

// Login Rate Limiter (In-Memory Sliding Window)
type LoginRateLimiter struct {
	attempts map[string][]time.Time
	mutex    sync.Mutex
}

var limiter = LoginRateLimiter{
	attempts: make(map[string][]time.Time),
}

func init() {
	// Periodic cleanup of the rate limiter map every 15 minutes
	go func() {
		for {
			time.Sleep(15 * time.Minute)
			limiter.mutex.Lock()
			now := time.Now()
			for key, times := range limiter.attempts {
				var validTimes []time.Time
				for _, t := range times {
					if now.Sub(t) < 15*time.Minute {
						validTimes = append(validTimes, t)
					}
				}
				if len(validTimes) == 0 {
					delete(limiter.attempts, key)
				} else {
					limiter.attempts[key] = validTimes
				}
			}
			limiter.mutex.Unlock()
		}
	}()
}

// Allow checks if the login attempt from this key (IP or email) is allowed (max 5 per 15 minutes)
func (l *LoginRateLimiter) Allow(key string) bool {
	l.mutex.Lock()
	defer l.mutex.Unlock()

	now := time.Now()
	times := l.attempts[key]

	// Filter out attempts older than 15 minutes
	var activeTimes []time.Time
	for _, t := range times {
		if now.Sub(t) < 15*time.Minute {
			activeTimes = append(activeTimes, t)
		}
	}

	if len(activeTimes) >= 5 {
		return false
	}

	activeTimes = append(activeTimes, now)
	l.attempts[key] = activeTimes
	return true
}

// Brevo Email Integration API Client
func sendWelcomeEmail(recipientEmail, recipientName string) error {
	apiKey := os.Getenv("BREVO_API_KEY")
	senderEmail := os.Getenv("BREVO_SENDER_EMAIL")
	senderName := os.Getenv("BREVO_SENDER_NAME")

	if apiKey == "" || senderEmail == "" {
		log.Println("Brevo Email API is not configured (missing key/sender email). Skipping welcome email.")
		return nil
	}

	if senderName == "" {
		senderName = "Reel App"
	}

	payload := map[string]interface{}{
		"sender": map[string]string{
			"name":  senderName,
			"email": senderEmail,
		},
		"to": []map[string]string{
			{
				"email": recipientEmail,
				"name":  recipientName,
			},
		},
		"subject":     "Welcome to Reel!",
		"htmlContent": fmt.Sprintf("<html><body><h1>Welcome to Reel, %s!</h1><p>Your account has been successfully created. Enjoy secure messaging!</p></body></html>", recipientName),
	}

	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequest("POST", "https://api.brevo.com/v3/smtp/email", bytes.NewBuffer(payloadBytes))
	if err != nil {
		return err
	}

	req.Header.Set("api-key", apiKey)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("brevo API error (HTTP %d): %s", resp.StatusCode, string(body))
	}

	log.Printf("Welcome email sent via Brevo to %s", recipientEmail)
	return nil
}

// Brevo Verification Code Email sender
func sendVerificationCodeEmail(recipientEmail, code string) error {
	apiKey := os.Getenv("BREVO_API_KEY")
	senderEmail := os.Getenv("BREVO_SENDER_EMAIL")
	senderName := os.Getenv("BREVO_SENDER_NAME")

	if apiKey == "" || senderEmail == "" {
		log.Println("Brevo Email API is not configured (missing key/sender email). Skipping verification email.")
		return nil
	}

	if senderName == "" {
		senderName = "Reel App"
	}

	payload := map[string]interface{}{
		"sender": map[string]string{
			"name":  senderName,
			"email": senderEmail,
		},
		"to": []map[string]string{
			{
				"email": recipientEmail,
				"name":  "Reel User",
			},
		},
		"subject":     "Confirm your email address - Reel",
		"htmlContent": fmt.Sprintf("<html><body><h1>Confirm your email address</h1><p>Thank you for signing up for Reel! Please use the following 6-digit code to verify your email address:</p><h2>%s</h2><p>This code is valid for 10 minutes. If you did not request this code, you can safely ignore this email.</p></body></html>", code),
	}

	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequest("POST", "https://api.brevo.com/v3/smtp/email", bytes.NewBuffer(payloadBytes))
	if err != nil {
		return err
	}

	req.Header.Set("api-key", apiKey)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("brevo API error (HTTP %d): %s", resp.StatusCode, string(body))
	}

	log.Printf("Verification code email sent via Brevo to %s", recipientEmail)
	return nil
}

// Helper to generate a random 32-character refresh token
func generateRefreshToken() string {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		// Fallback to timestamp + uuid if rand fails
		return hex.EncodeToString([]byte(fmt.Sprintf("%d-%s", time.Now().UnixNano(), uuid.New().String())))
	}
	return hex.EncodeToString(b)
}
