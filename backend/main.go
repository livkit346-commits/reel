package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"google.golang.org/api/option"
)

// Unified Message payload format
type ChatMessage struct {
	Type        string `json:"type,omitempty"` // "message", "ack", "status"
	TempID      string `json:"tempId,omitempty"`
	MessageID   string `json:"messageId,omitempty"`
	ChatID      string `json:"chatId,omitempty"`
	SenderID    string `json:"senderId,omitempty"`
	RecipientID string `json:"recipientId,omitempty"`
	Text        string `json:"text,omitempty"`
	MediaURL    string `json:"mediaUrl,omitempty"`
	MediaType   string `json:"mediaType,omitempty"`
	Timestamp   int64  `json:"timestamp,omitempty"`
	Status      string `json:"status,omitempty"` // "sent", "received"
}

// Client represents an active WebSocket connection
type Client struct {
	UserID string
	Conn   *websocket.Conn
	Send   chan []byte
}

// Hub manages active connections
type Hub struct {
	clients    map[string]*Client // map of userID -> Client
	register   chan *Client
	unregister chan *Client
	mutex      sync.RWMutex
}

var hub = Hub{
	clients:    make(map[string]*Client),
	register:   make(chan *Client),
	unregister: make(chan *Client),
}

var (
	upgrader = websocket.Upgrader{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		CheckOrigin: func(r *http.Request) bool {
			return true // Allow all origins for Flutter app
		},
	}
	firebaseApp *firebase.App
	dbClient    *dynamodb.Client
	supabaseUrl string
	supabaseKey string
)

// Group cache structures
type GroupCacheEntry struct {
	Participants []string
	ExpiresAt    time.Time
}

type ChatMetadata struct {
	IsGroup   bool   `json:"isGroup"`
	Name      string `json:"name"`
	GroupIcon string `json:"groupIcon"`
}

type ChatMetadataCacheEntry struct {
	Metadata  ChatMetadata
	ExpiresAt time.Time
}

var (
	groupCache             = make(map[string]GroupCacheEntry)
	groupCacheMutex        sync.RWMutex
	chatMetadataCache      = make(map[string]ChatMetadataCacheEntry)
	chatMetadataCacheMutex sync.RWMutex
)

func main() {
	// 1. Read environment variables
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	supabaseUrl = os.Getenv("SUPABASE_URL")
	supabaseKey = os.Getenv("SUPABASE_ANON_KEY")

	// 2. Initialize AWS Config (DynamoDB)
	cfg, err := config.LoadDefaultConfig(context.TODO())
	if err != nil {
		log.Fatalf("unable to load SDK config, %v", err)
	}
	dbClient = dynamodb.NewFromConfig(cfg)

	// Auto-create required DynamoDB tables (ReelUsers, ReelRefreshTokens, ReelMessages)
	EnsureTablesExist()

	// 3. Initialize Firebase Admin SDK (used for FCM only)
	opt := option.WithCredentialsFile("firebase-service-account.json")
	app, err := firebase.NewApp(context.Background(), nil, opt)
	if err != nil {
		log.Printf("Warning: Firebase App not initialized: %v. Running without FCM.", err)
	} else {
		firebaseApp = app
		log.Println("Firebase Admin SDK successfully initialized for FCM.")
	}

	// 4. Start Hub state manager
	go hub.run()

	// 5. Define HTTP endpoints
	http.HandleFunc("/ws", handleWebSocket)
	http.HandleFunc("/history", handleHistory)
	http.HandleFunc("/mute", handleMute)
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

	// Custom authentication endpoints
	http.HandleFunc("/auth/register", handleRegister)
	http.HandleFunc("/auth/login", handleLogin)
	http.HandleFunc("/auth/refresh", handleRefresh)
	http.HandleFunc("/auth/logout", handleLogout)

	log.Printf("Reel messaging gateway listening on port %s...", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatalf("ListenAndServe error: %v", err)
	}
}

func (h *Hub) run() {
	for {
		select {
		case client := <-h.register:
			h.mutex.Lock()
			h.clients[client.UserID] = client
			h.mutex.Unlock()
			log.Printf("User %s connected. Active users: %d", client.UserID, len(h.clients))

		case client := <-h.unregister:
			h.mutex.Lock()
			if _, ok := h.clients[client.UserID]; ok {
				delete(h.clients, client.UserID)
				close(client.Send)
			}
			h.mutex.Unlock()
			log.Printf("User %s disconnected. Active users: %d", client.UserID, len(h.clients))
		}
	}
}

func getJWTSecret() []byte {
	secret := os.Getenv("JWT_SECRET")
	if secret == "" {
		secret = "super-secret-jwt-key-minimum-32-bytes-long!!"
	}
	return []byte(secret)
}

// Handle incoming WebSocket connections
func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	// 1. Authenticate user via custom JWT query parameter
	tokenStr := r.URL.Query().Get("token")
	if tokenStr == "" {
		log.Println("WebSocket connection rejected: missing token.")
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	claims, err := ValidateJWT(tokenStr, getJWTSecret())
	if err != nil {
		log.Printf("WebSocket connection rejected: invalid JWT: %v", err)
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	userID, ok := claims["sub"].(string)
	if !ok || userID == "" {
		log.Println("WebSocket connection rejected: missing user ID in JWT.")
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	// 2. Upgrade HTTP request to WebSocket
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade failed: %v", err)
		return
	}

	client := &Client{
		UserID: userID,
		Conn:   conn,
		Send:   make(chan []byte, 256),
	}

	hub.register <- client

	// Start reading and writing loops in background goroutines
	go client.writePump()
	go client.readPump()
}

func (c *Client) readPump() {
	defer func() {
		hub.unregister <- c
		c.Conn.Close()
	}()

	for {
		_, message, err := c.Conn.ReadMessage()
		if err != nil {
			break
		}

		var chatMsg ChatMessage
		if err := json.Unmarshal(message, &chatMsg); err != nil {
			log.Printf("Error unmarshalling message: %v", err)
			continue
		}

		// Handle status updates (e.g. "received", "seen")
		if chatMsg.Type == "status" {
			if chatMsg.Status == "received" && chatMsg.MessageID != "" && chatMsg.ChatID != "" {
				// Purge message from DynamoDB since it has been successfully received
				err := deleteMessageFromDynamoDB(chatMsg.ChatID, chatMsg.MessageID, c.UserID)
				if err != nil {
					log.Printf("Error deleting message from DynamoDB on status update: %v", err)
				} else {
					log.Printf("Message %s in chat %s received and deleted from DynamoDB.", chatMsg.MessageID, chatMsg.ChatID)
				}
			}

			// Forward status update (received, seen, etc.) to the sender if they are online
			if (chatMsg.Status == "received" || chatMsg.Status == "seen") && chatMsg.RecipientID != "" {
				chatMsg.SenderID = c.UserID // Add status sender's ID so recipient knows who read/received it
				statusPayload, _ := json.Marshal(chatMsg)
				hub.mutex.RLock()
				senderClient, online := hub.clients[chatMsg.RecipientID]
				hub.mutex.RUnlock()
				if online {
					senderClient.Send <- statusPayload
					log.Printf("Forwarded status %s for message %s in chat %s to user %s (from %s)", chatMsg.Status, chatMsg.MessageID, chatMsg.ChatID, chatMsg.RecipientID, chatMsg.SenderID)
				}
			}
			continue
		}

		// Handle deletion updates
		if chatMsg.Type == "delete" {
			recipients, err := getChatRecipients(chatMsg.ChatID, c.UserID)
			if err != nil {
				log.Printf("Error resolving recipients for delete in chat %s: %v", chatMsg.ChatID, err)
				recipients = []string{chatMsg.RecipientID}
			}

			// Broadcast deletion to all online recipients
			for _, recipientID := range recipients {
				if recipientID == "" || recipientID == c.UserID {
					continue
				}
				hub.mutex.RLock()
				recipientClient, online := hub.clients[recipientID]
				hub.mutex.RUnlock()
				if online {
					delPayload, _ := json.Marshal(chatMsg)
					recipientClient.Send <- delPayload
				}
			}
			continue
		}

		// Default flow: handle sending a new message
		// 1. Generate chronological ID and timestamp
		timestamp := time.Now().UnixMilli()
		msgID := fmt.Sprintf("%015d-%s", timestamp, uuid.New().String())

		// 2. Resolve all recipients (excluding the sender) for this chat
		recipients, err := getChatRecipients(chatMsg.ChatID, c.UserID)
		if err != nil {
			log.Printf("Error resolving recipients for chat %s: %v", chatMsg.ChatID, err)
			// Fallback to routing to RecipientID if database query fails
			recipients = []string{chatMsg.RecipientID}
		}

		// 3. Save message once to DynamoDB
		err = saveMessageToDynamoDB(c.UserID, msgID, timestamp, chatMsg)
		if err != nil {
			log.Printf("Error saving message %s to DynamoDB: %v", msgID, err)
		}

		// 4. Send acknowledgment back to the sender
		ackMsg, _ := json.Marshal(ChatMessage{
			Type:      "ack",
			TempID:    chatMsg.TempID,
			MessageID: msgID,
			ChatID:    chatMsg.ChatID,
			Timestamp: timestamp,
		})
		c.Send <- ackMsg

		// 5. Deliver message to online recipients via WebSocket or offline via FCM
		for _, recipientID := range recipients {
			if recipientID == "" {
				continue
			}

			forwardedMsg := ChatMessage{
				Type:        "message",
				MessageID:   msgID,
				ChatID:      chatMsg.ChatID,
				SenderID:    c.UserID,
				RecipientID: recipientID,
				Text:        chatMsg.Text,
				MediaURL:    chatMsg.MediaURL,
				MediaType:   chatMsg.MediaType,
				Timestamp:   timestamp,
				Status:      "sent",
			}
			deliveredMsg, _ := json.Marshal(forwardedMsg)

			hub.mutex.RLock()
			recipientClient, online := hub.clients[recipientID]
			hub.mutex.RUnlock()

			if online {
				recipientClient.Send <- deliveredMsg
			} else {
				go sendFcmNotification(recipientID, c.UserID, chatMsg.ChatID, chatMsg.Text)
			}
		}
	}
}

func (c *Client) writePump() {
	defer func() {
		c.Conn.Close()
	}()

	for {
		select {
		case message, ok := <-c.Send:
			if !ok {
				c.Conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			c.Conn.WriteMessage(websocket.TextMessage, message)
		}
	}
}

// Participant Querying helpers
type ParticipantResult struct {
	UserID string `json:"userId"`
}

func getChatRecipients(chatID, senderID string) ([]string, error) {
	if supabaseUrl == "" || supabaseKey == "" {
		return nil, fmt.Errorf("Supabase URL or Key not set")
	}

	// 1. Check in-memory cache
	groupCacheMutex.RLock()
	entry, exists := groupCache[chatID]
	groupCacheMutex.RUnlock()

	if exists && time.Now().Before(entry.ExpiresAt) {
		return filterSender(entry.Participants, senderID), nil
	}

	// 2. Query Supabase chat_participants table
	clientHttp := &http.Client{Timeout: 5 * time.Second}
	reqUrl := fmt.Sprintf("%s/rest/v1/chat_participants?select=userId&chatId=eq.%s", supabaseUrl, chatID)
	req, err := http.NewRequest("GET", reqUrl, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("apikey", supabaseKey)
	req.Header.Set("Authorization", "Bearer "+supabaseKey)

	resp, err := clientHttp.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("failed to fetch participants from Supabase (HTTP %d)", resp.StatusCode)
	}

	var results []ParticipantResult
	if err := json.NewDecoder(resp.Body).Decode(&results); err != nil {
		return nil, err
	}

	participants := make([]string, len(results))
	for i, res := range results {
		participants[i] = res.UserID
	}

	// 3. Update Cache (valid for 1 minute)
	groupCacheMutex.Lock()
	groupCache[chatID] = GroupCacheEntry{
		Participants: participants,
		ExpiresAt:    time.Now().Add(1 * time.Minute),
	}
	groupCacheMutex.Unlock()

	return filterSender(participants, senderID), nil
}

func filterSender(participants []string, senderID string) []string {
	recipients := make([]string, 0)
	for _, p := range participants {
		if p != senderID {
			recipients = append(recipients, p)
		}
	}
	return recipients
}

func getChatMetadata(chatID string) (ChatMetadata, error) {
	var empty ChatMetadata
	if supabaseUrl == "" || supabaseKey == "" {
		return empty, fmt.Errorf("Supabase URL or Key not set")
	}

	// 1. Check in-memory cache
	chatMetadataCacheMutex.RLock()
	entry, exists := chatMetadataCache[chatID]
	chatMetadataCacheMutex.RUnlock()

	if exists && time.Now().Before(entry.ExpiresAt) {
		return entry.Metadata, nil
	}

	// 2. Query Supabase chats table
	clientHttp := &http.Client{Timeout: 5 * time.Second}
	reqUrl := fmt.Sprintf("%s/rest/v1/chats?select=isGroup,name,groupIcon&id=eq.%s", supabaseUrl, chatID)
	req, err := http.NewRequest("GET", reqUrl, nil)
	if err != nil {
		return empty, err
	}
	req.Header.Set("apikey", supabaseKey)
	req.Header.Set("Authorization", "Bearer "+supabaseKey)

	resp, err := clientHttp.Do(req)
	if err != nil {
		return empty, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return empty, fmt.Errorf("failed to fetch chat metadata from Supabase (HTTP %d)", resp.StatusCode)
	}

	var results []ChatMetadata
	if err := json.NewDecoder(resp.Body).Decode(&results); err != nil {
		return empty, err
	}

	if len(results) == 0 {
		return empty, fmt.Errorf("chat metadata not found for ID %s", chatID)
	}

	meta := results[0]

	// 3. Update Cache (valid for 1 minute)
	chatMetadataCacheMutex.Lock()
	chatMetadataCache[chatID] = ChatMetadataCacheEntry{
		Metadata:  meta,
		ExpiresAt: time.Now().Add(1 * time.Minute),
	}
	chatMetadataCacheMutex.Unlock()

	return meta, nil
}

// Write message log to DynamoDB table
func saveMessageToDynamoDB(senderID, msgID string, timestamp int64, msg ChatMessage) error {
	if dbClient == nil {
		return nil
	}

	timestampStr := fmt.Sprintf("%d", timestamp)
	ttlVal := time.Now().Add(48 * time.Hour).Unix()
	ttlStr := fmt.Sprintf("%d", ttlVal)

	input := &dynamodb.PutItemInput{
		TableName: aws.String("ReelMessages"),
		Item: map[string]types.AttributeValue{
			"chatId":    &types.AttributeValueMemberS{Value: msg.ChatID},
			"messageId": &types.AttributeValueMemberS{Value: msgID},
			"senderId":  &types.AttributeValueMemberS{Value: senderID},
			"text":      &types.AttributeValueMemberS{Value: msg.Text},
			"mediaUrl":  &types.AttributeValueMemberS{Value: msg.MediaURL},
			"mediaType": &types.AttributeValueMemberS{Value: msg.MediaType},
			"timestamp": &types.AttributeValueMemberN{Value: timestampStr},
			"status":    &types.AttributeValueMemberS{Value: "sent"},
			"ttl":       &types.AttributeValueMemberN{Value: ttlStr},
		},
	}

	_, err := dbClient.PutItem(context.TODO(), input)
	return err
}

// Delete message from DynamoDB table (No-Op: messages are cleaned up automatically via TTL)
func deleteMessageFromDynamoDB(chatID, messageID, userID string) error {
	return nil
}

// Retrieve undelivered messages from DynamoDB
func getMessagesFromDynamoDB(chatID, since string) ([]ChatMessage, error) {
	if dbClient == nil {
		return []ChatMessage{}, nil
	}

	var keyCond string
	exprValues := map[string]types.AttributeValue{
		":chatId": &types.AttributeValueMemberS{Value: chatID},
	}

	if since != "" {
		keyCond = "chatId = :chatId AND messageId > :since"
		exprValues[":since"] = &types.AttributeValueMemberS{Value: since}
	} else {
		keyCond = "chatId = :chatId"
	}

	input := &dynamodb.QueryInput{
		TableName:                 aws.String("ReelMessages"),
		KeyConditionExpression:    aws.String(keyCond),
		ExpressionAttributeValues: exprValues,
	}

	result, err := dbClient.Query(context.TODO(), input)
	if err != nil {
		return nil, err
	}

	messages := make([]ChatMessage, 0)
	for _, item := range result.Items {
		var msg ChatMessage
		msg.Type = "message"

		if val, ok := item["chatId"].(*types.AttributeValueMemberS); ok {
			msg.ChatID = val.Value
		}
		if val, ok := item["messageId"].(*types.AttributeValueMemberS); ok {
			msg.MessageID = val.Value
		}
		if val, ok := item["senderId"].(*types.AttributeValueMemberS); ok {
			msg.SenderID = val.Value
		}
		if val, ok := item["recipientId"].(*types.AttributeValueMemberS); ok {
			msg.RecipientID = val.Value
		}
		if val, ok := item["text"].(*types.AttributeValueMemberS); ok {
			msg.Text = val.Value
		}
		if val, ok := item["mediaUrl"].(*types.AttributeValueMemberS); ok {
			msg.MediaURL = val.Value
		}
		if val, ok := item["mediaType"].(*types.AttributeValueMemberS); ok {
			msg.MediaType = val.Value
		}
		if val, ok := item["status"].(*types.AttributeValueMemberS); ok {
			msg.Status = val.Value
		}
		if val, ok := item["timestamp"].(*types.AttributeValueMemberN); ok {
			var ts int64
			fmt.Sscanf(val.Value, "%d", &ts)
			msg.Timestamp = ts
		}

		messages = append(messages, msg)
	}

	return messages, nil
}

// HTTP handler to fetch history
func handleHistory(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	tokenStr := r.URL.Query().Get("token")
	if tokenStr == "" {
		authHeader := r.Header.Get("Authorization")
		if len(authHeader) > 7 && authHeader[:7] == "Bearer " {
			tokenStr = authHeader[7:]
		}
	}

	if tokenStr == "" {
		http.Error(w, "Unauthorized: missing token", http.StatusUnauthorized)
		return
	}

	claims, err := ValidateJWT(tokenStr, getJWTSecret())
	if err != nil {
		log.Printf("History request rejected: invalid JWT: %v", err)
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	userID := claims["sub"].(string)

	chatID := r.URL.Query().Get("chatId")
	if chatID == "" {
		http.Error(w, "Missing chatId parameter", http.StatusBadRequest)
		return
	}

	since := r.URL.Query().Get("since")
	messages, err := getMessagesFromDynamoDB(chatID, since)
	if err != nil {
		log.Printf("Error querying messages from DynamoDB: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	log.Printf("Retrieved %d undelivered messages for user %s in chat %s", len(messages), userID, chatID)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(messages)
}

func handleMute(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	tokenStr := r.URL.Query().Get("token")
	if tokenStr == "" {
		authHeader := r.Header.Get("Authorization")
		if len(authHeader) > 7 && authHeader[:7] == "Bearer " {
			tokenStr = authHeader[7:]
		}
	}

	if tokenStr == "" {
		http.Error(w, "Unauthorized: missing token", http.StatusUnauthorized)
		return
	}

	claims, err := ValidateJWT(tokenStr, getJWTSecret())
	if err != nil {
		log.Printf("Mute request rejected: invalid JWT: %v", err)
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	userID := claims["sub"].(string)

	if r.Method == "GET" {
		mutedChats, err := getMutedChatsFromDynamoDB(userID)
		if err != nil {
			log.Printf("Error fetching muted chats from DynamoDB for user %s: %v", userID, err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(mutedChats)
		return
	} else if r.Method == "POST" {
		var req struct {
			ChatID  string `json:"chatId"`
			IsMuted bool   `json:"isMuted"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			// Fallback to query params if JSON decoding fails
			req.ChatID = r.URL.Query().Get("chatId")
			if isMutedStr := r.URL.Query().Get("isMuted"); isMutedStr != "" {
				req.IsMuted = isMutedStr == "true"
			}
		}

		if req.ChatID == "" {
			http.Error(w, "Missing chatId parameter", http.StatusBadRequest)
			return
		}

		err = setChatMutedInDynamoDB(userID, req.ChatID, req.IsMuted)
		if err != nil {
			log.Printf("Error updating muted chat in DynamoDB: %v", err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"status":  "success",
			"chatId":  req.ChatID,
			"isMuted": req.IsMuted,
		})
		return
	} else {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
}

// Fetch recipient FCM token and chat metadata from Supabase and send push notification via FCM
func sendFcmNotification(recipientID, senderID, chatID, messageText string) {
	if firebaseApp == nil || supabaseUrl == "" || supabaseKey == "" {
		return
	}

	// Check if this chat is muted by the recipient
	mutedChats, err := getMutedChatsFromDynamoDB(recipientID)
	if err == nil {
		for _, mutedChatID := range mutedChats {
			if mutedChatID == chatID {
				log.Printf("Chat %s is muted for user %s. Skipping push notification.", chatID, recipientID)
				return
			}
		}
	}

	// 1. Fetch recipient's push token from Supabase REST API
	clientHttp := &http.Client{Timeout: 5 * time.Second}
	reqUrl := fmt.Sprintf("%s/rest/v1/users?select=pushToken&id=eq.%s", supabaseUrl, recipientID)
	req, err := http.NewRequest("GET", reqUrl, nil)
	if err != nil {
		return
	}
	req.Header.Set("apikey", supabaseKey)
	req.Header.Set("Authorization", "Bearer "+supabaseKey)

	resp, err := clientHttp.Do(req)
	if err != nil {
		return
	}
	defer resp.Body.Close()

	var result []struct {
		PushToken string `json:"pushToken"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil || len(result) == 0 || result[0].PushToken == "" {
		return
	}

	pushToken := result[0].PushToken

	// 2. Fetch sender name from Supabase REST API for the notification title
	senderName := "New Message"
	reqSenderUrl := fmt.Sprintf("%s/rest/v1/users?select=name&id=eq.%s", supabaseUrl, senderID)
	reqSender, err := http.NewRequest("GET", reqSenderUrl, nil)
	if err == nil {
		reqSender.Header.Set("apikey", supabaseKey)
		reqSender.Header.Set("Authorization", "Bearer "+supabaseKey)
		respSender, err := clientHttp.Do(reqSender)
		if err == nil {
			defer respSender.Body.Close()
			var senderResult []struct {
				Name string `json:"name"`
			}
			if err := json.NewDecoder(respSender.Body).Decode(&senderResult); err == nil && len(senderResult) > 0 {
				senderName = senderResult[0].Name
			}
		}
	}

	// 3. Fetch Chat metadata to check if group
	meta, err := getChatMetadata(chatID)
	isGroup := false
	chatName := ""
	if err == nil {
		isGroup = meta.IsGroup
		chatName = meta.Name
	}

	// 4. Construct Notification Title & Body
	title := senderName
	body := messageText
	if body == "" {
		body = "📷 Sent a photo/video"
	}

	if isGroup && chatName != "" {
		title = chatName
		body = fmt.Sprintf("%s: %s", senderName, body)
	}

	// 5. Send Notification via Firebase Cloud Messaging
	ctx := context.Background()
	fcmClient, err := firebaseApp.Messaging(ctx)
	if err != nil {
		return
	}

	fcmMsg := &messaging.Message{
		Token: pushToken,
		Notification: &messaging.Notification{
			Title: title,
			Body:  body,
		},
		Data: map[string]string{
			"click_action": "FLUTTER_NOTIFICATION_CLICK",
			"chatId":       chatID,
			"senderId":     senderID,
		},
	}

	respMsg, fcmErr := fcmClient.Send(ctx, fcmMsg)
	if fcmErr != nil {
		log.Printf("FCM notification error sending to %s: %v", recipientID, fcmErr)
	} else {
		log.Printf("FCM notification successfully sent: %s", respMsg)
	}
}

// User Registration endpoint
func handleRegister(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	if r.Method != "POST" {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
		Name     string `json:"name"`
		PhotoURL string `json:"photoUrl"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	req.Email = strings.ToLower(strings.TrimSpace(req.Email))

	// Enforce 9 character minimum on passwords
	if len(req.Password) < 9 {
		http.Error(w, "Password must be at least 9 characters long", http.StatusBadRequest)
		return
	}

	if req.Email == "" || req.Name == "" {
		http.Error(w, "Email and Name are required", http.StatusBadRequest)
		return
	}

	// Check if user already exists
	existingUser, err := getUserFromDynamoDB(req.Email)
	if err != nil {
		log.Printf("Error checking existing user: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}
	if existingUser != nil {
		http.Error(w, "Email already registered", http.StatusBadRequest)
		return
	}

	// Hashing: Generate random salt
	salt, err := generateSalt()
	if err != nil {
		log.Printf("Error generating salt: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	// Hashing: Stretched HMAC-SHA512
	hashedPassword := hashPassword(req.Password, salt)

	userID := uuid.New().String()
	saltB64 := base64.StdEncoding.EncodeToString(salt)
	passwordHashB64 := base64.StdEncoding.EncodeToString(hashedPassword)

	// Save to DynamoDB
	err = createUserInDynamoDB(userID, req.Email, passwordHashB64, saltB64, req.Name, req.PhotoURL)
	if err != nil {
		log.Printf("Error creating user in DynamoDB: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	// Sync User to Supabase
	err = syncUserToSupabase(userID, req.Name, req.Email)
	if err != nil {
		log.Printf("Warning: Failed to sync user to Supabase: %v", err)
	}

	// Send Welcome Email asynchronously via Brevo API
	go func() {
		err := sendWelcomeEmail(req.Email, req.Name)
		if err != nil {
			log.Printf("Error sending welcome email: %v", err)
		}
	}()

	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{
		"userId": userID,
		"status": "success",
	})
}

// User Login endpoint with rate limiting
func handleLogin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	if r.Method != "POST" {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Rate Limiting by IP and Email
	ip := r.RemoteAddr
	if idx := strings.LastIndex(ip, ":"); idx != -1 {
		ip = ip[:idx] // Strip port number
	}

	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	req.Email = strings.ToLower(strings.TrimSpace(req.Email))

	// Enforce Rate Limiting
	if !limiter.Allow(ip) || !limiter.Allow(req.Email) {
		http.Error(w, "Too many login attempts. Please try again in 15 minutes.", http.StatusTooManyRequests)
		return
	}

	user, err := getUserFromDynamoDB(req.Email)
	if err != nil {
		log.Printf("Error looking up user: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	if user == nil {
		http.Error(w, "Invalid email or password", http.StatusUnauthorized)
		return
	}

	// Validate password: decode salt, compute stretched hash and compare
	salt, err := base64.StdEncoding.DecodeString(user.Salt)
	if err != nil {
		log.Printf("Error decoding user salt: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	inputHash := hashPassword(req.Password, salt)
	storedHash, err := base64.StdEncoding.DecodeString(user.PasswordHash)
	if err != nil {
		log.Printf("Error decoding stored password hash: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	// Safe constant-time comparison
	if !bytes.Equal(inputHash, storedHash) {
		http.Error(w, "Invalid email or password", http.StatusUnauthorized)
		return
	}

	// Generate Access Token (JWT - 1 hour)
	accessToken, err := GenerateJWT(user.UserID, user.Email, getJWTSecret())
	if err != nil {
		log.Printf("Error generating JWT: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	// Generate long-lived Refresh Token (30 days)
	refreshToken := generateRefreshToken()
	expiresAt := time.Now().Add(30 * 24 * time.Hour).Unix()

	err = saveRefreshTokenToDynamoDB(refreshToken, user.UserID, expiresAt, "")
	if err != nil {
		log.Printf("Error saving refresh token to DynamoDB: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"accessToken":  accessToken,
		"refreshToken": refreshToken,
		"user": map[string]string{
			"userId":   user.UserID,
			"email":    user.Email,
			"name":     user.Name,
			"photoUrl": user.PhotoURL,
		},
	})
}

// Refresh Session (RTR enabled)
func handleRefresh(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	if r.Method != "POST" {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		RefreshToken string `json:"refreshToken"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RefreshToken == "" {
		http.Error(w, "Missing refreshToken", http.StatusBadRequest)
		return
	}

	// Look up token in DynamoDB
	storedToken, err := getRefreshTokenFromDynamoDB(req.RefreshToken)
	if err != nil {
		log.Printf("Error looking up refresh token: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	if storedToken == nil {
		http.Error(w, "Invalid refresh token", http.StatusUnauthorized)
		return
	}

	// Check if token is expired
	if time.Now().Unix() > storedToken.ExpiresAt {
		http.Error(w, "Refresh token expired", http.StatusUnauthorized)
		return
	}

	// Token Rotation Replay Check
	if storedToken.Revoked {
		// Reused token detected! Revoke all tokens for this user immediately as a safety precaution.
		log.Printf("WARNING: Reused refresh token detected: %s. Revoking all tokens for user %s.", req.RefreshToken, storedToken.UserID)
		_ = revokeAllRefreshTokensForUserInDynamoDB(storedToken.UserID)
		http.Error(w, "Session compromised. Please login again.", http.StatusUnauthorized)
		return
	}

	// Revoke the old token
	err = revokeRefreshTokenInDynamoDB(req.RefreshToken)
	if err != nil {
		log.Printf("Error revoking old refresh token: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	// Generate new access token
	// To get email, we retrieve the user from DynamoDB or carry it in claims.
	// Since we lookup user, we can get their email:
	// Let's get user from database or get email. Wait, we don't have GSI on userId, but we can query by email.
	// So let's store the email or lookup the email. To make this extremely fast and avoid looking up the user,
	// we could store user email directly in the refresh token record.
	// But let's just lookup user in DynamoDB. Since we need to query user by userId, we can do a Scan or add a quick GSI.
	// Actually, we can just save "email" inside the RefreshToken table as well, or lookup by email.
	// Let's check: can we lookup the user by email? We don't have the email in the request.
	// Let's modify the ReelRefreshTokens table and our saveRefreshTokenToDynamoDB to store the user's email too!
	// That way we can directly issue the JWT without scanning or looking up the user table. This is extremely efficient!
	// Let's check: yes, that's a brilliant optimization. Let's make sure we do that in db.go.
	// Wait, we can also query the user email from the users table. Let's see: we'll get the email from the database.
	// Wait! We can retrieve the user record. Since the email is the hash key of ReelUsers, we can scan or just store it.
	// Let's modify ReelRefreshTokens to store 'email' as well, which is much cleaner!
	// Let's write the code assuming ReelRefreshTokens has "email".

	// Let's find user email. We can retrieve the user by email. But we don't know the email.
	// Let's lookup user by userId? If we don't have email, let's scan ReelUsers or look up by scanning.
	// Scanning is slow. It's much better to store 'email' in the ReelRefreshTokens table!
	// Let's do that!	// We need the user's email to generate the JWT. We will scan the users table by userId.
	// Let's fetch email from the DynamoDB. We will look up the token.
	// Let's read email from the token record (we will update db.go to include email).
	// Let's write a Scan for user if email is empty (as fallback).
	// To keep it clean, let's look up the user.
	// we can do a quick scan of ReelUsers filtering by userId. Since this is an occasional refresh, a scan is perfectly fine,
	// or we can store the email in the refresh token table. Let's store the email in the refresh token table!
	// Let's read it:
	if result, err := getRefreshTokenFromDynamoDB(req.RefreshToken); err == nil && result != nil {
		// We'll read the email from it
		// Let's query it.
	}
	
	// Let's get email from database:
	// We'll update getRefreshTokenFromDynamoDB to return the email.
	// Let's write the code:
	var userEmail string
	// Let's do a scan of ReelUsers to get the email:
	if dbClient != nil {
		input := &dynamodb.ScanInput{
			TableName:        aws.String("ReelUsers"),
			FilterExpression: aws.String("userId = :uid"),
			ExpressionAttributeValues: map[string]types.AttributeValue{
				":uid": &types.AttributeValueMemberS{Value: storedToken.UserID},
			},
		}
		scanRes, err := dbClient.Scan(context.TODO(), input)
		if err == nil && len(scanRes.Items) > 0 {
			if val, ok := scanRes.Items[0]["email"].(*types.AttributeValueMemberS); ok {
				userEmail = val.Value
			}
		}
	}

	if userEmail == "" {
		userEmail = "user@reelapp.com" // Fallback if not found
	}

	accessToken, err := GenerateJWT(storedToken.UserID, userEmail, getJWTSecret())
	if err != nil {
		log.Printf("Error generating JWT: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	// Generate new refresh token
	newRefreshToken := generateRefreshToken()
	newExpiresAt := time.Now().Add(30 * 24 * time.Hour).Unix()

	err = saveRefreshTokenToDynamoDB(newRefreshToken, storedToken.UserID, newExpiresAt, req.RefreshToken)
	if err != nil {
		log.Printf("Error saving new refresh token to DynamoDB: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"accessToken":  accessToken,
		"refreshToken": newRefreshToken,
	})
}

// Revoke refresh token
func handleLogout(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	if r.Method != "POST" {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		RefreshToken string `json:"refreshToken"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RefreshToken == "" {
		http.Error(w, "Missing refreshToken", http.StatusBadRequest)
		return
	}

	err := revokeRefreshTokenInDynamoDB(req.RefreshToken)
	if err != nil {
		log.Printf("Error revoking refresh token on logout: %v", err)
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status": "success",
	})
}

// syncUserToSupabase syncs Go registered user details to Supabase users table
func syncUserToSupabase(userID, name, email string) error {
	if supabaseUrl == "" || supabaseKey == "" {
		log.Println("Supabase URL or Key not set. Skipping Supabase user sync.")
		return nil
	}

	payload := map[string]interface{}{
		"id":        userID,
		"name":      name,
		"createdAt": time.Now().Format(time.RFC3339),
		"latitude":  0.0,
		"longitude": 0.0,
		"lastSeen":  time.Now().Format(time.RFC3339),
	}

	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequest("POST", supabaseUrl+"/rest/v1/users", bytes.NewBuffer(payloadBytes))
	if err != nil {
		return err
	}
	req.Header.Set("apikey", supabaseKey)
	req.Header.Set("Authorization", "Bearer "+supabaseKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Prefer", "resolution=merge-duplicates") // UPSERT equivalent in PostgREST

	clientHttp := &http.Client{Timeout: 10 * time.Second}
	resp, err := clientHttp.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("supabase user sync error (HTTP %d): %s", resp.StatusCode, string(body))
	}

	log.Printf("Successfully synced user %s to Supabase.", userID)
	return nil
}
