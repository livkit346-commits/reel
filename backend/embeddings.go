package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net/http"
	"os"
	"strings"
	"time"
)

// List of 384 common keywords spanning social media topics for local vector fallback
var recommendationKeywords = []string{
	"coding", "programming", "golang", "flutter", "dart", "python", "javascript", "developer", "software", "tech",
	"funny", "meme", "joke", "comedy", "laugh", "humor", "lol", "hilarious", "parody", "satire",
	"dance", "music", "song", "singer", "guitar", "piano", "beat", "rap", "hiphop", "pop",
	"love", "relationship", "dating", "couple", "heart", "romance", "marriage", "crush", "friend", "family",
	"food", "recipe", "cooking", "chef", "delicious", "bake", "pizza", "burger", "dessert", "healthy",
	"travel", "trip", "adventure", "beach", "mountain", "nature", "vacation", "explore", "wanderlust", "flight",
	"fitness", "gym", "workout", "run", "yoga", "muscle", "healthy", "diet", "cardio", "training",
	"gaming", "gamer", "playstation", "xbox", "nintendo", "pc", "streamer", "twitch", "fortnite", "minecraft",
	"sports", "football", "soccer", "basketball", "tennis", "golf", "workout", "athlete", "championship", "stadium",
	"business", "money", "startup", "invest", "crypto", "bitcoin", "finance", "rich", "marketing", "sales",
	"science", "space", "galaxy", "nasa", "physics", "chemistry", "biology", "earth", "future", "ai",
	"art", "drawing", "painting", "illustration", "design", "creative", "artist", "craft", "diy", "sketch",
	"fashion", "style", "outfit", "makeup", "beauty", "hair", "model", "clothes", "runway", "shopping",
	"photography", "photo", "camera", "lens", "video", "shoot", "capture", "portrait", "landscape", "drone",
	"news", "politics", "world", "current", "breaking", "update", "report", "history", "education", "learn",
	"motivation", "inspire", "quote", "success", "mindset", "focus", "goals", "dream", "growth", "life",
	"crypto", "blockchain", "nft", "ethereum", "web3", "miner", "trading", "stocks", "wallstreet", "economy",
	"pets", "dog", "cat", "puppy", "kitten", "animal", "cute", "rabbit", "bird", "veterinarian",
	"gaming", "gamedev", "rpg", "fps", "e-sports", "retro", "arcade", "consoles", "cosplay", "boardgames",
	"automotive", "car", "motorcycle", "race", "supercar", "tesla", "engine", "drift", "drive", "garage",
	"home", "interior", "garden", "decor", "architecture", "renovation", "furniture", "cleaning", "diy", "plants",
	"movies", "cinema", "show", "series", "netflix", "anime", "hollywood", "actor", "director", "popcorn",
	"books", "reading", "write", "author", "novel", "poetry", "library", "study", "knowledge", "philosophy",
	"mentalhealth", "mindfulness", "meditation", "calm", "anxiety", "peace", "therapy", "wellness", "sleep", "healing",
	"gadgets", "phone", "iphone", "android", "laptop", "smartwatch", "headphones", "review", "unboxing", "setup",
	"cooking", "vegan", "vegetarian", "keto", "organic", "restaurant", "streetfood", "spicy", "sweet", "drinks",
	"history", "ancient", "museum", "archaeology", "empire", "war", "documentary", "culture", "tradition", "heritage",
	"crafts", "origami", "knitting", "sewing", "woodworking", "pottery", "handmade", "scrapbook", "hobbies", "skills",
	"astrology", "horoscope", "stars", "zodiac", "tarot", "magic", "mystery", "spiritual", "universe", "cosmic",
	"environment", "climate", "recycle", "green", "solar", "eco", "ocean", "forest", "wildlife", "conservation",
	"diy", "tutorial", "hack", "tips", "tricks", "guide", "how-to", "advice", "instructions", "solution",
	"comedy", "standup", "prank", "reaction", "fails", "vlog", "lifestyle", "routine", "daily", "weekend",
	"coding", "database", "sql", "postgres", "supabase", "docker", "kubernetes", "cloud", "aws", "security",
	"design", "ux", "ui", "figma", "frontend", "backend", "fullstack", "api", "web", "mobile",
	"music", "instrument", "drums", "vocals", "concert", "festival", "band", "dj", "remix", "soundtrack",
	"sports", "swimming", "cycling", "hiking", "climbing", "skiing", "snowboard", "surfing", "skate", "running",
	"business", "passiveincome", "sidehustle", "freelance", "remote", "productivity", "time", "habits", "journal", "planning",
	"viral", "trending", "challenge", "pov", "storytime", "unpopularopinion", "q&a", "behindthescenes", "hack", "secrets",
	"future", "robot", "vr", "ar", "metaverse", "quantum", "nano", "biotech", "energy", "fusion",
}

func init() {
	// Seed random generator
	rand.Seed(time.Now().UnixNano())
}

// GenerateEmbedding attempts to get semantic 384-dimensional vector from HuggingFace, falling back to keyword mapping
func GenerateEmbedding(text string) ([]float32, error) {
	// Clean text
	textClean := strings.ToLower(strings.TrimSpace(text))
	if textClean == "" {
		// Return small random unit vector
		return generateRandomUnitVector(384), nil
	}

	// 1. Try HuggingFace Inference API (Free)
	embedding, err := fetchHuggingFaceEmbedding(textClean)
	if err == nil && len(embedding) == 384 {
		return embedding, nil
	}

	if err != nil {
		fmt.Printf("Warning: HuggingFace embedding failed (%v). Using local keyword-vector fallback.\n", err)
	}

	// 2. Local Fallback: Keyword-based vectorization
	return generateLocalKeywordVector(textClean), nil
}

// Fetch embeddings using HuggingFace sentence-transformers API (free)
func fetchHuggingFaceEmbedding(text string) ([]float32, error) {
	url := "https://api-inference.huggingface.co/pipeline/feature-extraction/sentence-transformers/all-MiniLM-L6-v2"
	
	reqBody, err := json.Marshal(map[string]interface{}{
		"inputs": text,
		"options": map[string]bool{
			"wait_for_model": true,
		},
	})
	if err != nil {
		return nil, err
	}

	client := &http.Client{Timeout: 4 * time.Second}
	req, err := http.NewRequest("POST", url, bytes.NewBuffer(reqBody))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	// Optional: HuggingFace API key from environment variable if available
	hfToken := os.Getenv("HUGGINGFACE_API_KEY")
	if hfToken != "" {
		req.Header.Set("Authorization", "Bearer "+hfToken)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("HuggingFace status %d: %s", resp.StatusCode, string(bodyBytes))
	}

	var result []float32
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	return result, nil
}

// Generate local keyword matches normalized to a unit vector
func generateLocalKeywordVector(text string) []float32 {
	vector := make([]float32, 384)
	
	// Pre-fill with tiny random noise to avoid zero-vector issues
	for i := 0; i < 384; i++ {
		vector[i] = (rand.Float32()*2 - 1) * 0.005
	}

	hasMatches := false
	// Set matching keyword elements to 1.0
	for idx, kw := range recommendationKeywords {
		if idx >= 384 {
			break
		}
		// Match keyword as full word or sub-word
		if strings.Contains(text, kw) {
			vector[idx] += 1.0
			hasMatches = true
		}
	}

	// If no matches, add a small random seed to some indices
	if !hasMatches {
		for i := 0; i < 10; i++ {
			randIdx := rand.Intn(384)
			vector[randIdx] += 0.5
		}
	}

	// Normalize vector to unit length
	var sumSquares float64
	for i := 0; i < 384; i++ {
		sumSquares += float64(vector[i] * vector[i])
	}
	magnitude := math.Sqrt(sumSquares)

	if magnitude > 0 {
		for i := 0; i < 384; i++ {
			vector[i] = float32(float64(vector[i]) / magnitude)
		}
	}

	return vector
}

// Generates a random normalized unit vector of specified dimension
func generateRandomUnitVector(dim int) []float32 {
	vector := make([]float32, dim)
	var sumSquares float64
	
	for i := 0; i < dim; i++ {
		vector[i] = rand.Float32()*2 - 1
		sumSquares += float64(vector[i] * vector[i])
	}

	magnitude := math.Sqrt(sumSquares)
	if magnitude > 0 {
		for i := 0; i < dim; i++ {
			vector[i] = float32(float64(vector[i]) / magnitude)
		}
	}
	return vector
}
