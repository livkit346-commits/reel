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
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"google.golang.org/api/option"
)

// Message payload format
type ChatMessage struct {
	ChatID      string `json:"chatId"`
	RecipientID string `json:"recipientId"`
	Text        string `json:"text"`
	MediaURL    string `json:"mediaUrl"`
	MediaType   string `json:"mediaType"`
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

		// 1. Write message to DynamoDB
		err = saveMessageToDynamoDB(c.UserID, chatMsg)
		if err != nil {
			log.Printf("Error saving to DynamoDB: %v", err)
		}

		// 2. Deliver message
		deliveredMsg, _ := json.Marshal(map[string]interface{}{
			"chatId":      chatMsg.ChatID,
			"senderId":    c.UserID,
			"text":        chatMsg.Text,
			"mediaUrl":    chatMsg.MediaURL,
			"mediaType":   chatMsg.MediaType,
			"timestamp":   time.Now().UnixMilli(),
			"messageId":   uuid.New().String(),
		})

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
func saveMessageToDynamoDB(senderID string, msg ChatMessage) error {
	if dbClient == nil {
		return nil
	}

	msgID := uuid.New().String()
	timestampStr := fmt.Sprintf("%d", time.Now().UnixMilli())

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
