;; Storm Drain Registry Contract
;; Manages storm drain registration, mapping, maintenance scheduling, and flood risk assessment
;; Version: 1.0.0

;; Error constants
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_DRAIN_NOT_FOUND (err u101))
(define-constant ERR_DRAIN_ALREADY_EXISTS (err u102))
(define-constant ERR_INVALID_COORDINATES (err u103))
(define-constant ERR_INVALID_RISK_LEVEL (err u104))
(define-constant ERR_MAINTENANCE_NOT_FOUND (err u105))
(define-constant ERR_INVALID_STATUS (err u106))

;; Contract owner
(define-data-var contract-owner principal tx-sender)

;; Drain ID counter
(define-data-var next-drain-id uint u1)

;; Maintenance ID counter
(define-data-var next-maintenance-id uint u1)

;; Storm drain data structure
(define-map drains
  uint ;; drain-id
  {
    location: {x: uint, y: uint}, ;; GPS coordinates as integers
    description: (string-ascii 500),
    capacity: uint, ;; liters per second
    installation-date: uint,
    last-inspection: uint,
    status: (string-ascii 20), ;; "active", "inactive", "maintenance"
    flood-risk-level: uint, ;; 1-5 scale
    registered-by: principal,
    registration-timestamp: uint
  }
)

;; Maintenance schedule data structure
(define-map maintenance-schedules
  uint ;; maintenance-id
  {
    drain-id: uint,
    maintenance-type: (string-ascii 100),
    scheduled-date: uint,
    completed-date: (optional uint),
    assigned-crew: (string-ascii 200),
    priority: uint, ;; 1-5 scale
    notes: (string-ascii 1000),
    status: (string-ascii 20), ;; "scheduled", "in-progress", "completed", "cancelled"
    created-by: principal,
    created-timestamp: uint
  }
)

;; Drain location index for spatial queries
(define-map location-index
  {x: uint, y: uint}
  uint ;; drain-id
)

;; Owner management
(define-map authorized-inspectors principal bool)

;; Public function: Register a new storm drain
(define-public (register-drain 
  (location-x uint) 
  (location-y uint) 
  (description (string-ascii 500))
  (capacity uint)
  (installation-date uint)
  (flood-risk-level uint))
  (let 
    (
      (drain-id (var-get next-drain-id))
      (location {x: location-x, y: location-y})
    )
    ;; Validate inputs
    (asserts! (and (> location-x u0) (> location-y u0)) ERR_INVALID_COORDINATES)
    (asserts! (and (>= flood-risk-level u1) (<= flood-risk-level u5)) ERR_INVALID_RISK_LEVEL)
    (asserts! (is-none (map-get? location-index location)) ERR_DRAIN_ALREADY_EXISTS)
    
    ;; Create drain record
    (map-set drains drain-id {
      location: location,
      description: description,
      capacity: capacity,
      installation-date: installation-date,
      last-inspection: u0,
      status: "active",
      flood-risk-level: flood-risk-level,
      registered-by: tx-sender,
      registration-timestamp: stacks-block-height
    })
    
    ;; Update location index
    (map-set location-index location drain-id)
    
    ;; Increment counter
    (var-set next-drain-id (+ drain-id u1))
    
    (ok drain-id)
  )
)

;; Public function: Update drain status
(define-public (update-drain-status (drain-id uint) (new-status (string-ascii 20)))
  (let 
    (
      (drain-data (unwrap! (map-get? drains drain-id) ERR_DRAIN_NOT_FOUND))
    )
    ;; Check authorization
    (asserts! (or 
      (is-eq tx-sender (var-get contract-owner))
      (is-eq tx-sender (get registered-by drain-data))
      (default-to false (map-get? authorized-inspectors tx-sender))
    ) ERR_NOT_AUTHORIZED)
    
    ;; Validate status
    (asserts! (or 
      (is-eq new-status "active")
      (is-eq new-status "inactive")
      (is-eq new-status "maintenance")
    ) ERR_INVALID_STATUS)
    
    ;; Update drain
    (map-set drains drain-id (merge drain-data {status: new-status}))
    
    (ok true)
  )
)

;; Public function: Record inspection
(define-public (record-inspection (drain-id uint) (flood-risk-level uint))
  (let 
    (
      (drain-data (unwrap! (map-get? drains drain-id) ERR_DRAIN_NOT_FOUND))
    )
    ;; Check authorization
    (asserts! (or 
      (is-eq tx-sender (var-get contract-owner))
      (default-to false (map-get? authorized-inspectors tx-sender))
    ) ERR_NOT_AUTHORIZED)
    
    ;; Validate risk level
    (asserts! (and (>= flood-risk-level u1) (<= flood-risk-level u5)) ERR_INVALID_RISK_LEVEL)
    
    ;; Update inspection data
    (map-set drains drain-id (merge drain-data {
      last-inspection: stacks-block-height,
      flood-risk-level: flood-risk-level
    }))
    
    (ok true)
  )
)

;; Public function: Schedule maintenance
(define-public (schedule-maintenance
  (drain-id uint)
  (maintenance-type (string-ascii 100))
  (scheduled-date uint)
  (assigned-crew (string-ascii 200))
  (priority uint)
  (notes (string-ascii 1000)))
  (let 
    (
      (maintenance-id (var-get next-maintenance-id))
      (drain-data (unwrap! (map-get? drains drain-id) ERR_DRAIN_NOT_FOUND))
    )
    ;; Check authorization
    (asserts! (or 
      (is-eq tx-sender (var-get contract-owner))
      (default-to false (map-get? authorized-inspectors tx-sender))
    ) ERR_NOT_AUTHORIZED)
    
    ;; Validate priority
    (asserts! (and (>= priority u1) (<= priority u5)) ERR_INVALID_RISK_LEVEL)
    
    ;; Create maintenance record
    (map-set maintenance-schedules maintenance-id {
      drain-id: drain-id,
      maintenance-type: maintenance-type,
      scheduled-date: scheduled-date,
      completed-date: none,
      assigned-crew: assigned-crew,
      priority: priority,
      notes: notes,
      status: "scheduled",
      created-by: tx-sender,
      created-timestamp: stacks-block-height
    })
    
    ;; Increment counter
    (var-set next-maintenance-id (+ maintenance-id u1))
    
    (ok maintenance-id)
  )
)

;; Public function: Complete maintenance
(define-public (complete-maintenance (maintenance-id uint))
  (let 
    (
      (maintenance-data (unwrap! (map-get? maintenance-schedules maintenance-id) ERR_MAINTENANCE_NOT_FOUND))
    )
    ;; Check authorization
    (asserts! (or 
      (is-eq tx-sender (var-get contract-owner))
      (is-eq tx-sender (get created-by maintenance-data))
      (default-to false (map-get? authorized-inspectors tx-sender))
    ) ERR_NOT_AUTHORIZED)
    
    ;; Update maintenance record
    (map-set maintenance-schedules maintenance-id (merge maintenance-data {
      completed-date: (some stacks-block-height),
      status: "completed"
    }))
    
    (ok true)
  )
)

;; Public function: Add authorized inspector
(define-public (add-authorized-inspector (inspector principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (map-set authorized-inspectors inspector true)
    (ok true)
  )
)

;; Public function: Remove authorized inspector
(define-public (remove-authorized-inspector (inspector principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (map-delete authorized-inspectors inspector)
    (ok true)
  )
)

;; Read-only function: Get drain details
(define-read-only (get-drain (drain-id uint))
  (map-get? drains drain-id)
)

;; Read-only function: Get drain by location
(define-read-only (get-drain-by-location (location-x uint) (location-y uint))
  (let 
    (
      (drain-id (map-get? location-index {x: location-x, y: location-y}))
    )
    (match drain-id
      some-id (map-get? drains some-id)
      none
    )
  )
)

;; Read-only function: Get maintenance details
(define-read-only (get-maintenance (maintenance-id uint))
  (map-get? maintenance-schedules maintenance-id)
)

;; Read-only function: Check if inspector is authorized
(define-read-only (is-authorized-inspector (inspector principal))
  (default-to false (map-get? authorized-inspectors inspector))
)

;; Read-only function: Get contract owner
(define-read-only (get-contract-owner)
  (var-get contract-owner)
)

;; Read-only function: Get next drain ID
(define-read-only (get-next-drain-id)
  (var-get next-drain-id)
)

;; Read-only function: Get next maintenance ID
(define-read-only (get-next-maintenance-id)
  (var-get next-maintenance-id)
)

