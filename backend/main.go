package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
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

	// 3. Initialize Firebase Admin SDK
	opt := option.WithCredentialsFile("firebase-service-account.json")
	app, err := firebase.NewApp(context.Background(), nil, opt)
	if err != nil {
		log.Printf("Warning: Firebase App not initialized: %v. Running in debug mode without Auth/FCM.", err)
	} else {
		firebaseApp = app
		log.Println("Firebase Admin SDK successfully initialized.")
	}

	// 4. Start Hub state manager
	go hub.run()

	// 5. Define HTTP endpoints
	http.HandleFunc("/ws", handleWebSocket)
	http.HandleFunc("/history", handleHistory)
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

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

// Handle incoming WebSocket connections
func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	// 1. Authenticate user via Firebase Token query parameter
	tokenStr := r.URL.Query().Get("token")
	var userID string

	if firebaseApp != nil {
		ctx := context.Background()
		authClient, err := firebaseApp.Auth(ctx)
		if err != nil {
			http.Error(w, "Auth initialization error", http.StatusInternalServerError)
			return
		}
		decodedToken, err := authClient.VerifyIDToken(ctx, tokenStr)
		if err != nil {
			log.Printf("Failed to verify token: %v", err)
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		userID = decodedToken.UID
	} else {
		// Fallback for local testing if credentials file not provided
		userID = r.URL.Query().Get("userId")
		if userID == "" {
			userID = "test-user-" + uuid.New().String()[:8]
		}
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

		// Handle status updates (e.g. "received")
		if chatMsg.Type == "status" {
			if chatMsg.Status == "received" && chatMsg.MessageID != "" && chatMsg.ChatID != "" {
				// Purge message from DynamoDB since it has been successfully received
				err := deleteMessageFromDynamoDB(chatMsg.ChatID, chatMsg.MessageID)
				if err != nil {
					log.Printf("Error deleting message from DynamoDB on status update: %v", err)
				} else {
					log.Printf("Message %s in chat %s received and deleted from DynamoDB.", chatMsg.MessageID, chatMsg.ChatID)
				}

				// Forward status update to the sender if they are online
				if chatMsg.RecipientID != "" { // Recipient of status is the sender of the original message
					statusPayload, _ := json.Marshal(chatMsg)
					hub.mutex.RLock()
					senderClient, online := hub.clients[chatMsg.RecipientID]
					hub.mutex.RUnlock()
					if online {
						senderClient.Send <- statusPayload
					}
				}
			}
			continue
		}

		// Default flow: handle sending a new message
		// 1. Generate chronological ID and timestamp
		timestamp := time.Now().UnixMilli()
		msgID := fmt.Sprintf("%015d-%s", timestamp, uuid.New().String())

		// 2. Save message to DynamoDB
		err = saveMessageToDynamoDB(c.UserID, msgID, timestamp, chatMsg)
		if err != nil {
			log.Printf("Error saving to DynamoDB: %v", err)
		}

		// 3. Send acknowledgment back to the sender
		ackMsg, _ := json.Marshal(ChatMessage{
			Type:      "ack",
			TempID:    chatMsg.TempID,
			MessageID: msgID,
			ChatID:    chatMsg.ChatID,
			Timestamp: timestamp,
		})
		c.Send <- ackMsg

		// 4. Deliver message to recipient
		forwardedMsg := ChatMessage{
			Type:        "message",
			MessageID:   msgID,
			ChatID:      chatMsg.ChatID,
			SenderID:    c.UserID,
			RecipientID: chatMsg.RecipientID,
			Text:        chatMsg.Text,
			MediaURL:    chatMsg.MediaURL,
			MediaType:   chatMsg.MediaType,
			Timestamp:   timestamp,
			Status:      "sent",
		}
		deliveredMsg, _ := json.Marshal(forwardedMsg)

		hub.mutex.RLock()
		recipientClient, online := hub.clients[chatMsg.RecipientID]
		hub.mutex.RUnlock()

		if online {
			// Deliver instantly via open socket
			recipientClient.Send <- deliveredMsg
		} else {
			// Trigger FCM push notification since recipient is offline
			go sendFcmNotification(chatMsg.RecipientID, c.UserID, chatMsg.Text)
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

// Write message log to DynamoDB table
func saveMessageToDynamoDB(senderID, msgID string, timestamp int64, msg ChatMessage) error {
	if dbClient == nil {
		return nil
	}

	timestampStr := fmt.Sprintf("%d", timestamp)

	input := &dynamodb.PutItemInput{
		TableName: &[]string{"ReelMessages"}[0],
		Item: map[string]types.AttributeValue{
			"chatId":      &types.AttributeValueMemberS{Value: msg.ChatID},
			"messageId":   &types.AttributeValueMemberS{Value: msgID},
			"senderId":    &types.AttributeValueMemberS{Value: senderID},
			"recipientId": &types.AttributeValueMemberS{Value: msg.RecipientID},
			"text":        &types.AttributeValueMemberS{Value: msg.Text},
			"mediaUrl":    &types.AttributeValueMemberS{Value: msg.MediaURL},
			"mediaType":   &types.AttributeValueMemberS{Value: msg.MediaType},
			"timestamp":   &types.AttributeValueMemberN{Value: timestampStr},
			"status":      &types.AttributeValueMemberS{Value: "sent"},
		},
	}

	_, err := dbClient.PutItem(context.TODO(), input)
	return err
}

// Delete message from DynamoDB table
func deleteMessageFromDynamoDB(chatID, messageID string) error {
	if dbClient == nil {
		return nil
	}

	input := &dynamodb.DeleteItemInput{
		TableName: &[]string{"ReelMessages"}[0],
		Key: map[string]types.AttributeValue{
			"chatId":    &types.AttributeValueMemberS{Value: chatID},
			"messageId": &types.AttributeValueMemberS{Value: messageID},
		},
	}

	_, err := dbClient.DeleteItem(context.TODO(), input)
	return err
}

// Retrieve undelivered messages from DynamoDB
func getMessagesFromDynamoDB(chatID string) ([]ChatMessage, error) {
	if dbClient == nil {
		return []ChatMessage{}, nil
	}

	input := &dynamodb.QueryInput{
		TableName:              &[]string{"ReelMessages"}[0],
		KeyConditionExpression: aws.String("chatId = :chatId"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":chatId": &types.AttributeValueMemberS{Value: chatID},
		},
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

	var userID string
	if firebaseApp != nil {
		ctx := context.Background()
		authClient, err := firebaseApp.Auth(ctx)
		if err != nil {
			http.Error(w, "Auth initialization error", http.StatusInternalServerError)
			return
		}
		decodedToken, err := authClient.VerifyIDToken(ctx, tokenStr)
		if err != nil {
			log.Printf("Failed to verify token: %v", err)
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		userID = decodedToken.UID
	} else {
		userID = r.URL.Query().Get("userId")
		if userID == "" {
			userID = "debug-user"
		}
	}

	chatID := r.URL.Query().Get("chatId")
	if chatID == "" {
		http.Error(w, "Missing chatId parameter", http.StatusBadRequest)
		return
	}

	messages, err := getMessagesFromDynamoDB(chatID)
	if err != nil {
		log.Printf("Error querying messages from DynamoDB: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	log.Printf("Retrieved %d undelivered messages for user %s in chat %s", len(messages), userID, chatID)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(messages)
}

// Fetch recipient FCM token from Supabase and send push notification via FCM
func sendFcmNotification(recipientID, senderID, messageText string) {
	if firebaseApp == nil || supabaseUrl == "" || supabaseKey == "" {
		return
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

	// 3. Send Notification via Firebase Cloud Messaging
	ctx := context.Background()
	fcmClient, err := firebaseApp.Messaging(ctx)
	if err != nil {
		return
	}

	bodyText := messageText
	if bodyText == "" {
		bodyText = "📷 Sent a photo/video"
	}

	fcmMsg := &messaging.Message{
		Token: pushToken,
		Notification: &messaging.Notification{
			Title: senderName,
			Body:  bodyText,
		},
		Data: map[string]string{
			"click_action": "FLUTTER_NOTIFICATION_CLICK",
			"senderId":     senderID,
		},
	}

	_, _ = fcmClient.Send(ctx, fcmMsg)
}
