package main

import (
	"encoding/json"
	"io/ioutil"
	"log"
	"net/http"
)

type InstanceMetadata struct {
	Compute struct {
		ResourceGroupName string `json:"resourceGroupName"`
		SubscriptionID    string `json:"subscriptionId"`
	} `json:"compute"`
}

func getInstanceMetadata() *InstanceMetadata {
	client := &http.Client{}

	req, err := http.NewRequest("GET", "http://169.254.169.254/metadata/instance", nil)
	if err != nil {
		log.Fatal(err)
	}
	req.Header.Add("Metadata", "true")

	q := req.URL.Query()
	q.Add("api-version", "2018-10-01")
	req.URL.RawQuery = q.Encode()

	resp, err := client.Do(req)
	if err != nil {
		log.Fatal(err)
	}

	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		log.Fatal(err)
	}

	metadata := InstanceMetadata{}
	err = json.Unmarshal(body, &metadata)
	if err != nil {
		log.Fatal(err)
	}

	return &metadata
}
