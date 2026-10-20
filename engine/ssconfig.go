package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v2"
)

func yamlMap(v interface{}) map[interface{}]interface{} {
	if m, ok := v.(map[interface{}]interface{}); ok {
		return m
	}
	return nil
}

func yamlString(v interface{}) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func yamlInt(v interface{}) int {
	switch n := v.(type) {
	case int:
		return n
	case int64:
		return int(n)
	case float64:
		return int(n)
	default:
		return 0
	}
}

func yamlPluginPresent(v interface{}) bool {
	if v == nil {
		return false
	}
	if s, ok := v.(string); ok {
		return strings.TrimSpace(s) != ""
	}
	return true
}

func ssCandidates(yamlPath string) ([]map[interface{}]interface{}, error) {
	b, err := os.ReadFile(yamlPath)
	if err != nil {
		return nil, err
	}
	var root map[string]interface{}
	if err := yaml.Unmarshal(b, &root); err != nil {
		return nil, err
	}
	raw, ok := root["proxies"]
	if !ok {
		return nil, errors.New("yaml has no proxies")
	}
	list, ok := raw.([]interface{})
	if !ok {
		return nil, errors.New("yaml proxies is not a list")
	}
	out := make([]map[interface{}]interface{}, 0, len(list))
	for _, item := range list {
		m := yamlMap(item)
		if m == nil {
			continue
		}
		if yamlString(m["type"]) != "ss" {
			continue
		}
		if strings.ToLower(yamlString(m["cipher"])) != "aes-256-gcm" {
			continue
		}
		if yamlPluginPresent(m["plugin"]) {
			continue
		}
		name := yamlString(m["name"])
		server := yamlString(m["server"])
		password := yamlString(m["password"])
		port := yamlInt(m["port"])
		if name == "" || server == "" || password == "" || port <= 0 {
			continue
		}
		if isLoopbackSSServer(server) {
			continue
		}
		out = append(out, m)
	}
	return out, nil
}

func isLoopbackSSServer(server string) bool {
	s := strings.ToLower(strings.TrimSpace(server))
	if s == "localhost" {
		return true
	}
	ip := net.ParseIP(strings.Trim(s, "[]"))
	return ip != nil && ip.IsLoopback()
}

func ssNodesFromYAML(yamlPath string) ([]*ssNode, error) {
	candidates, err := ssCandidates(yamlPath)
	if err != nil {
		return nil, err
	}
	out := make([]*ssNode, 0, len(candidates))
	for _, m := range candidates {
		out = append(out, &ssNode{
			Name:     yamlString(m["name"]),
			Server:   yamlString(m["server"]),
			Port:     yamlInt(m["port"]),
			Cipher:   yamlString(m["cipher"]),
			Password: yamlString(m["password"]),
		})
	}
	return out, nil
}

func listSSNodes(yamlPath string) ([]map[string]interface{}, error) {
	nodes, err := ssCandidates(yamlPath)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]interface{}, 0, len(nodes))
	for _, m := range nodes {
		out = append(out, map[string]interface{}{
			"name":   yamlString(m["name"]),
			"port":   yamlInt(m["port"]),
			"cipher": yamlString(m["cipher"]),
		})
	}
	return out, nil
}

func selectSSNode(yamlPath string, name string) error {
	nodes, err := ssCandidates(yamlPath)
	if err != nil {
		return err
	}
	var chosen map[interface{}]interface{}
	for _, m := range nodes {
		if yamlString(m["name"]) == name {
			chosen = m
			break
		}
	}
	if chosen == nil {
		for _, m := range nodes {
			if strings.Contains(yamlString(m["name"]), name) {
				chosen = m
				break
			}
		}
	}
	if chosen == nil {
		return fmt.Errorf("ss node not found: %s", name)
	}
	out := map[string]interface{}{
		"name":     yamlString(chosen["name"]),
		"server":   yamlString(chosen["server"]),
		"port":     yamlInt(chosen["port"]),
		"cipher":   yamlString(chosen["cipher"]),
		"password": yamlString(chosen["password"]),
	}
	data, err := json.Marshal(out)
	if err != nil {
		return err
	}
	path := filepath.Join(filepath.Dir(yamlPath), "ss-node.json")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	logf("SS node selected: name=%s port=%d cipher=%s", yamlString(chosen["name"]), yamlInt(chosen["port"]), yamlString(chosen["cipher"]))
	return nil
}
