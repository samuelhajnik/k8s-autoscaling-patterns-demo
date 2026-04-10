package config

import (
	"os"
	"strconv"
)

type Config struct {
	Port             string
	DefaultWorkUnits int
}

func Load() Config {
	return Config{
		Port:             getEnv("PORT", "8080"),
		DefaultWorkUnits: getEnvInt("DEFAULT_WORK_UNITS", 200000),
	}
}

func getEnv(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}

func getEnvInt(key string, fallback int) int {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return parsed
}
