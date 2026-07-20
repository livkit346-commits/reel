package main

import (
	"context"
	"fmt"
	"log"
)

// User representation
type DBUser struct {
	UserID       string
	Email        string
	PasswordHash string
	Salt         string
	Name         string
	PhotoURL     string
}

// Refresh Token representation
type DBRefreshToken struct {
	Token       string
	UserID      string
	ExpiresAt   int64
	Revoked     bool
	ParentToken string
}

// Ensure required PostgreSQL tables exist
func EnsureTablesExist() {
	if dbPool == nil {
		log.Println("PostgreSQL pool is nil, skipping table check.")
		return
	}

	queries := []string{
		`CREATE TABLE IF NOT EXISTS public.auth_credentials (
			id UUID PRIMARY KEY,
			email VARCHAR(255) UNIQUE NOT NULL,
			password_hash VARCHAR(255) NOT NULL,
			salt VARCHAR(255) NOT NULL,
			created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS public.refresh_tokens (
			token VARCHAR(255) PRIMARY KEY,
			user_id UUID NOT NULL,
			expires_at BIGINT NOT NULL,
			revoked BOOLEAN DEFAULT false NOT NULL,
			parent_token VARCHAR(255)
		)`,
		`CREATE TABLE IF NOT EXISTS public.muted_chats (
			user_id VARCHAR(255) PRIMARY KEY,
			muted_chats TEXT[] NOT NULL DEFAULT '{}'::TEXT[]
		)`,
		`CREATE TABLE IF NOT EXISTS public.verification_codes (
			email VARCHAR(255) PRIMARY KEY,
			code VARCHAR(10) NOT NULL,
			expires_at BIGINT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS public.chat_messages (
			chat_id VARCHAR(255) NOT NULL,
			message_id VARCHAR(255) NOT NULL,
			sender_id VARCHAR(255) NOT NULL,
			recipient_id VARCHAR(255) NOT NULL,
			text TEXT,
			media_url TEXT,
			media_type VARCHAR(50),
			timestamp BIGINT NOT NULL,
			status VARCHAR(50) DEFAULT 'sent',
			expires_at BIGINT NOT NULL,
			PRIMARY KEY (chat_id, message_id)
		)`,
		`ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS "saves" INTEGER DEFAULT 0 NOT NULL`,
		`ALTER TABLE public.post_metrics ADD COLUMN IF NOT EXISTS "saved" BOOLEAN DEFAULT FALSE NOT NULL`,
	}

	for _, q := range queries {
		_, err := dbPool.Exec(context.Background(), q)
		if err != nil {
			log.Printf("Failed to run migration query: %v", err)
		}
	}
	log.Println("Successfully ran PostgreSQL database migrations/checks.")
}

// Create a new user credentials record
func createUserInDynamoDB(userID, email, passwordHashB64, saltB64, name, photoURL string) error {
	if dbPool == nil {
		return fmt.Errorf("PostgreSQL pool not initialized")
	}

	// Insert into public.auth_credentials. Note: public.users is already synced by syncUserToSupabase.
	query := `INSERT INTO public.auth_credentials (id, email, password_hash, salt) 
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email, password_hash = EXCLUDED.password_hash, salt = EXCLUDED.salt`

	_, err := dbPool.Exec(context.Background(), query, userID, email, passwordHashB64, saltB64)
	return err
}

// Update user's password
func updateUserPasswordInDynamoDB(email, passwordHashB64, saltB64 string) error {
	if dbPool == nil {
		return fmt.Errorf("PostgreSQL pool not initialized")
	}

	query := `UPDATE public.auth_credentials SET password_hash = $1, salt = $2 WHERE email = $3`
	_, err := dbPool.Exec(context.Background(), query, passwordHashB64, saltB64, email)
	return err
}

// Retrieve user credentials by email
func getUserFromDynamoDB(email string) (*DBUser, error) {
	if dbPool == nil {
		return nil, fmt.Errorf("PostgreSQL pool not initialized")
	}

	// Join with users table to get the name/photoUrl
	query := `SELECT c.id, c.email, c.password_hash, c.salt, COALESCE(u.name, ''), COALESCE(u."photoUrl", '') 
		FROM public.auth_credentials c
		LEFT JOIN public.users u ON u.id = c.id
		WHERE c.email = $1`

	var user DBUser
	err := dbPool.QueryRow(context.Background(), query, email).Scan(
		&user.UserID,
		&user.Email,
		&user.PasswordHash,
		&user.Salt,
		&user.Name,
		&user.PhotoURL,
	)
	if err != nil {
		// pgx returns ErrNoRows when no rows are found
		if err.Error() == "no rows in result set" {
			return nil, nil
		}
		return nil, err
	}

	return &user, nil
}

// Save a new refresh token
func saveRefreshTokenToDynamoDB(token, userID string, expiresAt int64, parentToken string) error {
	if dbPool == nil {
		return fmt.Errorf("PostgreSQL pool not initialized")
	}

	query := `INSERT INTO public.refresh_tokens (token, user_id, expires_at, revoked, parent_token) 
		VALUES ($1, $2, $3, $4, $5)`

	_, err := dbPool.Exec(context.Background(), query, token, userID, expiresAt, false, parentToken)
	return err
}

// Retrieve refresh token details
func getRefreshTokenFromDynamoDB(token string) (*DBRefreshToken, error) {
	if dbPool == nil {
		return nil, fmt.Errorf("PostgreSQL pool not initialized")
	}

	query := `SELECT token, user_id, expires_at, revoked, parent_token FROM public.refresh_tokens WHERE token = $1`

	var rt DBRefreshToken
	err := dbPool.QueryRow(context.Background(), query, token).Scan(
		&rt.Token,
		&rt.UserID,
		&rt.ExpiresAt,
		&rt.Revoked,
		&rt.ParentToken,
	)
	if err != nil {
		if err.Error() == "no rows in result set" {
			return nil, nil
		}
		return nil, err
	}

	return &rt, nil
}

// Revoke a specific refresh token (mark revoked = true)
func revokeRefreshTokenInDynamoDB(token string) error {
	if dbPool == nil {
		return fmt.Errorf("PostgreSQL pool not initialized")
	}

	query := `UPDATE public.refresh_tokens SET revoked = true WHERE token = $1`
	_, err := dbPool.Exec(context.Background(), query, token)
	return err
}

// Revoke all active refresh tokens for a user ID
func revokeAllRefreshTokensForUserInDynamoDB(userID string) error {
	if dbPool == nil {
		return fmt.Errorf("PostgreSQL pool not initialized")
	}

	query := `UPDATE public.refresh_tokens SET revoked = true WHERE user_id = $1`
	_, err := dbPool.Exec(context.Background(), query, userID)
	return err
}

// Retrieve muted chats for a user
func getMutedChatsFromDynamoDB(userID string) ([]string, error) {
	if dbPool == nil {
		return nil, fmt.Errorf("PostgreSQL pool not initialized")
	}

	query := `SELECT muted_chats FROM public.muted_chats WHERE user_id = $1`

	var mutedChats []string
	err := dbPool.QueryRow(context.Background(), query, userID).Scan(&mutedChats)
	if err != nil {
		if err.Error() == "no rows in result set" {
			return []string{}, nil
		}
		return nil, err
	}

	return mutedChats, nil
}

// Add/Remove a chat from the user's muted chats set
func setChatMutedInDynamoDB(userID string, chatID string, isMuted bool) error {
	if dbPool == nil {
		return fmt.Errorf("PostgreSQL pool not initialized")
	}

	// Fetch existing
	current, err := getMutedChatsFromDynamoDB(userID)
	if err != nil {
		current = []string{}
	}

	// Update list
	updatedMap := make(map[string]bool)
	for _, c := range current {
		updatedMap[c] = true
	}

	if isMuted {
		updatedMap[chatID] = true
	} else {
		delete(updatedMap, chatID)
	}

	var updated []string
	for c := range updatedMap {
		updated = append(updated, c)
	}

	// Save back using upsert (ON CONFLICT DO UPDATE)
	query := `INSERT INTO public.muted_chats (user_id, muted_chats) 
		VALUES ($1, $2)
		ON CONFLICT (user_id) DO UPDATE SET muted_chats = EXCLUDED.muted_chats`

	_, err = dbPool.Exec(context.Background(), query, userID, updated)
	return err
}

// Save verification code
func saveVerificationCode(email, code string, expiresAt int64) error {
	if dbPool == nil {
		return fmt.Errorf("PostgreSQL pool not initialized")
	}

	query := `INSERT INTO public.verification_codes (email, code, expires_at) 
		VALUES ($1, $2, $3)
		ON CONFLICT (email) DO UPDATE SET code = EXCLUDED.code, expires_at = EXCLUDED.expires_at`

	_, err := dbPool.Exec(context.Background(), query, email, code, expiresAt)
	return err
}

// Retrieve verification code details
func getVerificationCode(email string) (string, int64, error) {
	if dbPool == nil {
		return "", 0, fmt.Errorf("PostgreSQL pool not initialized")
	}

	query := `SELECT code, expires_at FROM public.verification_codes WHERE email = $1`

	var code string
	var expiresAt int64
	err := dbPool.QueryRow(context.Background(), query, email).Scan(&code, &expiresAt)
	if err != nil {
		if err.Error() == "no rows in result set" {
			return "", 0, nil
		}
		return "", 0, err
	}

	return code, expiresAt, nil
}

// Delete verification code
func deleteVerificationCode(email string) error {
	if dbPool == nil {
		return fmt.Errorf("PostgreSQL pool not initialized")
	}

	query := `DELETE FROM public.verification_codes WHERE email = $1`
	_, err := dbPool.Exec(context.Background(), query, email)
	return err
}
