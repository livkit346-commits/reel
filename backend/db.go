package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// DynamoDB User representation
type DBUser struct {
	UserID       string
	Email        string
	PasswordHash string
	Salt         string
	Name         string
	PhotoURL     string
}

// DynamoDB Refresh Token representation
type DBRefreshToken struct {
	Token       string
	UserID      string
	ExpiresAt   int64
	Revoked     bool
	ParentToken string
}

// Ensure required DynamoDB tables exist
func EnsureTablesExist() {
	if dbClient == nil {
		log.Println("DynamoDB client is nil, skipping table check.")
		return
	}

	tables := []struct {
		name      string
		hashKey   string
		enableTTL bool
	}{
		{"ReelUsers", "email", false},
		{"ReelRefreshTokens", "token", true},
		{"ReelMessages", "chatId", false}, // In case this table isn't created yet either
		{"ReelMutedChats", "userId", false},
		{"ReelVerificationCodes", "email", true},
	}

	for _, t := range tables {
		_, err := dbClient.DescribeTable(context.TODO(), &dynamodb.DescribeTableInput{
			TableName: aws.String(t.name),
		})
		if err != nil {
			var notFound *types.ResourceNotFoundException
			if errors.As(err, &notFound) {
				log.Printf("Table %s not found. Creating it...", t.name)
				err = createTable(t.name, t.hashKey)
				if err != nil {
					log.Printf("Failed to create table %s: %v", t.name, err)
					continue
				}

				if t.enableTTL {
					// Wait for table to be active before enabling TTL
					go func(tableName string) {
						time.Sleep(10 * time.Second)
						enableTTL(tableName, "expiresAt")
					}(t.name)
				}
			} else {
				log.Printf("Error describing table %s: %v", t.name, err)
			}
		} else {
			log.Printf("Table %s exists.", t.name)
		}
	}
}

func createTable(name, hashKey string) error {
	// For ReelMessages, we also need a Sort Key (messageId)
	var keySchema []types.KeySchemaElement
	var attrDefs []types.AttributeDefinition

	if name == "ReelMessages" {
		keySchema = []types.KeySchemaElement{
			{AttributeName: aws.String("chatId"), KeyType: types.KeyTypeHash},
			{AttributeName: aws.String("messageId"), KeyType: types.KeyTypeRange},
		}
		attrDefs = []types.AttributeDefinition{
			{AttributeName: aws.String("chatId"), AttributeType: types.ScalarAttributeTypeS},
			{AttributeName: aws.String("messageId"), AttributeType: types.ScalarAttributeTypeS},
		}
	} else {
		keySchema = []types.KeySchemaElement{
			{AttributeName: aws.String(hashKey), KeyType: types.KeyTypeHash},
		}
		attrDefs = []types.AttributeDefinition{
			{AttributeName: aws.String(hashKey), AttributeType: types.ScalarAttributeTypeS},
		}
	}

	input := &dynamodb.CreateTableInput{
		TableName:            aws.String(name),
		KeySchema:            keySchema,
		AttributeDefinitions: attrDefs,
		BillingMode:          types.BillingModePayPerRequest, // Serverless On-Demand scaling
	}

	_, err := dbClient.CreateTable(context.TODO(), input)
	return err
}

func enableTTL(tableName, attributeName string) {
	input := &dynamodb.UpdateTimeToLiveInput{
		TableName: aws.String(tableName),
		TimeToLiveSpecification: &types.TimeToLiveSpecification{
			AttributeName: aws.String(attributeName),
			Enabled:       aws.Bool(true),
		},
	}
	_, err := dbClient.UpdateTimeToLive(context.TODO(), input)
	if err != nil {
		log.Printf("Failed to enable TTL on table %s: %v", tableName, err)
	} else {
		log.Printf("Successfully enabled TTL on %s for attribute %s", tableName, attributeName)
	}
}

// Create a new user in ReelUsers table
func createUserInDynamoDB(userID, email, passwordHashB64, saltB64, name, photoURL string) error {
	if dbClient == nil {
		return fmt.Errorf("DynamoDB client not initialized")
	}

	input := &dynamodb.PutItemInput{
		TableName: aws.String("ReelUsers"),
		Item: map[string]types.AttributeValue{
			"email":        &types.AttributeValueMemberS{Value: email},
			"userId":       &types.AttributeValueMemberS{Value: userID},
			"passwordHash": &types.AttributeValueMemberS{Value: passwordHashB64},
			"salt":         &types.AttributeValueMemberS{Value: saltB64},
			"name":         &types.AttributeValueMemberS{Value: name},
			"photoUrl":     &types.AttributeValueMemberS{Value: photoURL},
			"createdAt":    &types.AttributeValueMemberN{Value: strconv.FormatInt(time.Now().UnixMilli(), 10)},
		},
	}

	_, err := dbClient.PutItem(context.TODO(), input)
	return err
}

// Retrieve user by email from ReelUsers table
func getUserFromDynamoDB(email string) (*DBUser, error) {
	if dbClient == nil {
		return nil, fmt.Errorf("DynamoDB client not initialized")
	}

	input := &dynamodb.GetItemInput{
		TableName: aws.String("ReelUsers"),
		Key: map[string]types.AttributeValue{
			"email": &types.AttributeValueMemberS{Value: email},
		},
	}

	result, err := dbClient.GetItem(context.TODO(), input)
	if err != nil {
		return nil, err
	}
	if result.Item == nil {
		return nil, nil // User not found
	}

	user := &DBUser{}
	if val, ok := result.Item["userId"].(*types.AttributeValueMemberS); ok {
		user.UserID = val.Value
	}
	if val, ok := result.Item["email"].(*types.AttributeValueMemberS); ok {
		user.Email = val.Value
	}
	if val, ok := result.Item["passwordHash"].(*types.AttributeValueMemberS); ok {
		user.PasswordHash = val.Value
	}
	if val, ok := result.Item["salt"].(*types.AttributeValueMemberS); ok {
		user.Salt = val.Value
	}
	if val, ok := result.Item["name"].(*types.AttributeValueMemberS); ok {
		user.Name = val.Value
	}
	if val, ok := result.Item["photoUrl"].(*types.AttributeValueMemberS); ok {
		user.PhotoURL = val.Value
	}

	return user, nil
}

// Save a new refresh token to ReelRefreshTokens table
func saveRefreshTokenToDynamoDB(token, userID string, expiresAt int64, parentToken string) error {
	if dbClient == nil {
		return fmt.Errorf("DynamoDB client not initialized")
	}

	input := &dynamodb.PutItemInput{
		TableName: aws.String("ReelRefreshTokens"),
		Item: map[string]types.AttributeValue{
			"token":       &types.AttributeValueMemberS{Value: token},
			"userId":      &types.AttributeValueMemberS{Value: userID},
			"expiresAt":   &types.AttributeValueMemberN{Value: strconv.FormatInt(expiresAt, 10)},
			"revoked":     &types.AttributeValueMemberBOOL{Value: false},
			"parentToken": &types.AttributeValueMemberS{Value: parentToken},
		},
	}

	_, err := dbClient.PutItem(context.TODO(), input)
	return err
}

// Retrieve refresh token from ReelRefreshTokens table
func getRefreshTokenFromDynamoDB(token string) (*DBRefreshToken, error) {
	if dbClient == nil {
		return nil, fmt.Errorf("DynamoDB client not initialized")
	}

	input := &dynamodb.GetItemInput{
		TableName: aws.String("ReelRefreshTokens"),
		Key: map[string]types.AttributeValue{
			"token": &types.AttributeValueMemberS{Value: token},
		},
	}

	result, err := dbClient.GetItem(context.TODO(), input)
	if err != nil {
		return nil, err
	}
	if result.Item == nil {
		return nil, nil // Token not found
	}

	rt := &DBRefreshToken{}
	if val, ok := result.Item["token"].(*types.AttributeValueMemberS); ok {
		rt.Token = val.Value
	}
	if val, ok := result.Item["userId"].(*types.AttributeValueMemberS); ok {
		rt.UserID = val.Value
	}
	if val, ok := result.Item["parentToken"].(*types.AttributeValueMemberS); ok {
		rt.ParentToken = val.Value
	}
	if val, ok := result.Item["revoked"].(*types.AttributeValueMemberBOOL); ok {
		rt.Revoked = val.Value
	}
	if val, ok := result.Item["expiresAt"].(*types.AttributeValueMemberN); ok {
		exp, _ := strconv.ParseInt(val.Value, 10, 64)
		rt.ExpiresAt = exp
	}

	return rt, nil
}

// Revoke a specific refresh token (mark revoked = true)
func revokeRefreshTokenInDynamoDB(token string) error {
	if dbClient == nil {
		return fmt.Errorf("DynamoDB client not initialized")
	}

	input := &dynamodb.UpdateItemInput{
		TableName: aws.String("ReelRefreshTokens"),
		Key: map[string]types.AttributeValue{
			"token": &types.AttributeValueMemberS{Value: token},
		},
		UpdateExpression:          aws.String("SET revoked = :r"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":r": &types.AttributeValueMemberBOOL{Value: true},
		},
	}

	_, err := dbClient.UpdateItem(context.TODO(), input)
	return err
}

// Revoke all active refresh tokens for a user ID (for token compromise response)
func revokeAllRefreshTokensForUserInDynamoDB(userID string) error {
	if dbClient == nil {
		return fmt.Errorf("DynamoDB client not initialized")
	}

	input := &dynamodb.ScanInput{
		TableName:        aws.String("ReelRefreshTokens"),
		FilterExpression: aws.String("userId = :uid AND revoked = :rev"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":uid": &types.AttributeValueMemberS{Value: userID},
			":rev": &types.AttributeValueMemberBOOL{Value: false},
		},
	}

	result, err := dbClient.Scan(context.TODO(), input)
	if err != nil {
		return err
	}

	for _, item := range result.Items {
		if tokenVal, ok := item["token"].(*types.AttributeValueMemberS); ok {
			err = revokeRefreshTokenInDynamoDB(tokenVal.Value)
			if err != nil {
				log.Printf("Failed to revoke token %s for user %s: %v", tokenVal.Value, userID, err)
			}
		}
	}

	return nil
}

// Retrieve muted chats for a user from ReelMutedChats table
func getMutedChatsFromDynamoDB(userID string) ([]string, error) {
	if dbClient == nil {
		return nil, fmt.Errorf("DynamoDB client not initialized")
	}

	input := &dynamodb.GetItemInput{
		TableName: aws.String("ReelMutedChats"),
		Key: map[string]types.AttributeValue{
			"userId": &types.AttributeValueMemberS{Value: userID},
		},
	}

	result, err := dbClient.GetItem(context.TODO(), input)
	if err != nil {
		return nil, err
	}
	if result.Item == nil {
		return []string{}, nil
	}

	var mutedChats []string
	if val, ok := result.Item["mutedChats"]; ok {
		if setVal, ok := val.(*types.AttributeValueMemberSS); ok {
			mutedChats = setVal.Value
		} else if listVal, ok := val.(*types.AttributeValueMemberL); ok {
			for _, item := range listVal.Value {
				if sItem, ok := item.(*types.AttributeValueMemberS); ok {
					mutedChats = append(mutedChats, sItem.Value)
				}
			}
		}
	}

	return mutedChats, nil
}

// Add/Remove a chat from the user's muted chats set in ReelMutedChats table
func setChatMutedInDynamoDB(userID string, chatID string, isMuted bool) error {
	if dbClient == nil {
		return fmt.Errorf("DynamoDB client not initialized")
	}

	// First get current list
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

	// Save back as a String Set (SS) or List (L)
	var attrVal types.AttributeValue
	if len(updated) > 0 {
		attrVal = &types.AttributeValueMemberSS{Value: updated}
	} else {
		// DynamoDB SS cannot be empty, so we store an empty list L instead
		attrVal = &types.AttributeValueMemberL{Value: []types.AttributeValue{}}
	}

	input := &dynamodb.PutItemInput{
		TableName: aws.String("ReelMutedChats"),
		Item: map[string]types.AttributeValue{
			"userId":     &types.AttributeValueMemberS{Value: userID},
			"mutedChats": attrVal,
		},
	}

	_, err = dbClient.PutItem(context.TODO(), input)
	return err
}

// Save verification code in ReelVerificationCodes table
func saveVerificationCode(email, code string, expiresAt int64) error {
	if dbClient == nil {
		return fmt.Errorf("DynamoDB client not initialized")
	}

	input := &dynamodb.PutItemInput{
		TableName: aws.String("ReelVerificationCodes"),
		Item: map[string]types.AttributeValue{
			"email":     &types.AttributeValueMemberS{Value: email},
			"code":      &types.AttributeValueMemberS{Value: code},
			"expiresAt": &types.AttributeValueMemberN{Value: strconv.FormatInt(expiresAt, 10)},
		},
	}
	_, err := dbClient.PutItem(context.TODO(), input)
	return err
}

// Retrieve verification code from ReelVerificationCodes table
func getVerificationCode(email string) (string, int64, error) {
	if dbClient == nil {
		return "", 0, fmt.Errorf("DynamoDB client not initialized")
	}

	input := &dynamodb.GetItemInput{
		TableName: aws.String("ReelVerificationCodes"),
		Key: map[string]types.AttributeValue{
			"email": &types.AttributeValueMemberS{Value: email},
		},
	}

	resp, err := dbClient.GetItem(context.TODO(), input)
	if err != nil {
		return "", 0, err
	}

	if resp.Item == nil {
		return "", 0, nil
	}

	codeVal, ok := resp.Item["code"].(*types.AttributeValueMemberS)
	if !ok {
		return "", 0, fmt.Errorf("invalid code attribute type")
	}

	expiresVal, ok := resp.Item["expiresAt"].(*types.AttributeValueMemberN)
	if !ok {
		return "", 0, fmt.Errorf("invalid expiresAt attribute type")
	}

	expiresAt, err := strconv.ParseInt(expiresVal.Value, 10, 64)
	if err != nil {
		return "", 0, err
	}

	return codeVal.Value, expiresAt, nil
}

// Delete verification code from ReelVerificationCodes table
func deleteVerificationCode(email string) error {
	if dbClient == nil {
		return fmt.Errorf("DynamoDB client not initialized")
	}

	input := &dynamodb.DeleteItemInput{
		TableName: aws.String("ReelVerificationCodes"),
		Key: map[string]types.AttributeValue{
			"email": &types.AttributeValueMemberS{Value: email},
		},
	}
	_, err := dbClient.DeleteItem(context.TODO(), input)
	return err
}
