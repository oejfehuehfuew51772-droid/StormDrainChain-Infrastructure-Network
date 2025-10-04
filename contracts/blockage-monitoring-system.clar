;; Blockage Monitoring System Contract
;; Monitors storm drain blockages, coordinates clearing activities, and manages emergency response
;; Version: 1.0.0

;; Error constants
(define-constant ERR_NOT_AUTHORIZED (err u200))
(define-constant ERR_BLOCKAGE_NOT_FOUND (err u201))
(define-constant ERR_INVALID_SEVERITY (err u202))
(define-constant ERR_INVALID_STATUS (err u203))
(define-constant ERR_CLEARING_NOT_FOUND (err u204))
(define-constant ERR_DRAIN_NOT_EXISTS (err u205))
(define-constant ERR_ALERT_NOT_FOUND (err u206))
(define-constant ERR_ALREADY_REPORTED (err u207))

;; Contract owner and system operators
(define-data-var contract-owner principal tx-sender)

;; Counters for unique IDs
(define-data-var next-blockage-id uint u1)
(define-data-var next-clearing-id uint u1)
(define-data-var next-alert-id uint u1)

;; Emergency response settings
(define-data-var emergency-threshold uint u4) ;; Severity level that triggers emergency
(define-data-var max-response-time uint u7200) ;; Max response time in blocks (~24 hours)

;; Blockage report data structure
(define-map blockage-reports
  uint ;; blockage-id
  {
    drain-location: {x: uint, y: uint},
    severity: uint, ;; 1-5 scale (1=minor, 5=complete blockage)
    blockage-type: (string-ascii 100), ;; "debris", "sediment", "structural", "vegetation"
    description: (string-ascii 1000),
    reported-by: principal,
    report-timestamp: uint,
    status: (string-ascii 20), ;; "reported", "verified", "clearing", "cleared", "false-alarm"
    verification-timestamp: (optional uint),
    verified-by: (optional principal),
    estimated-clearing-time: (optional uint),
    photos-hash: (optional (string-ascii 64)) ;; IPFS hash for photos
  }
)

;; Clearing activities data structure
(define-map clearing-activities
  uint ;; clearing-id
  {
    blockage-id: uint,
    assigned-crew: (string-ascii 200),
    start-time: uint,
    estimated-completion: uint,
    actual-completion: (optional uint),
    equipment-used: (string-ascii 500),
    clearing-method: (string-ascii 200),
    status: (string-ascii 20), ;; "assigned", "in-progress", "completed", "cancelled"
    notes: (string-ascii 1000),
    created-by: principal,
    completed-by: (optional principal)
  }
)

;; Emergency alerts data structure
(define-map emergency-alerts
  uint ;; alert-id
  {
    blockage-id: uint,
    alert-type: (string-ascii 50), ;; "flood-risk", "infrastructure-damage", "environmental"
    priority: uint, ;; 1-5 scale
    affected-area: (string-ascii 500),
    response-required: bool,
    alert-timestamp: uint,
    resolved-timestamp: (optional uint),
    status: (string-ascii 20), ;; "active", "acknowledged", "resolved", "false-alarm"
    response-team: (optional (string-ascii 200)),
    resolution-notes: (optional (string-ascii 1000))
  }
)

;; Authorized reporters and crews
(define-map authorized-reporters principal bool)
(define-map authorized-crews principal bool)

;; Location-based blockage tracking
(define-map location-blockages
  {x: uint, y: uint}
  (list 10 uint) ;; List of blockage IDs at this location
)

;; Severity-based priority queue
(define-map high-priority-blockages
  uint ;; severity level
  (list 100 uint) ;; List of blockage IDs
)

;; Public function: Report a blockage
(define-public (report-blockage
  (location-x uint)
  (location-y uint)
  (severity uint)
  (blockage-type (string-ascii 100))
  (description (string-ascii 1000))
  (photos-hash (optional (string-ascii 64))))
  (let 
    (
      (blockage-id (var-get next-blockage-id))
      (location {x: location-x, y: location-y})
    )
    ;; Validate inputs
    (asserts! (and (> location-x u0) (> location-y u0)) ERR_DRAIN_NOT_EXISTS)
    (asserts! (and (>= severity u1) (<= severity u5)) ERR_INVALID_SEVERITY)
    
    ;; Create blockage report
    (map-set blockage-reports blockage-id {
      drain-location: location,
      severity: severity,
      blockage-type: blockage-type,
      description: description,
      reported-by: tx-sender,
      report-timestamp: stacks-block-height,
      status: "reported",
      verification-timestamp: none,
      verified-by: none,
      estimated-clearing-time: none,
      photos-hash: photos-hash
    })
    
    ;; Update location tracking
    (let 
      (
        (existing-blockages (default-to (list) (map-get? location-blockages location)))
      )
      (map-set location-blockages location (unwrap! (as-max-len? (append existing-blockages blockage-id) u10) ERR_INVALID_STATUS))
    )
    
    ;; Add to priority queue if high severity
    (if (>= severity u4)
      (let 
        (
          (high-priority-list (default-to (list) (map-get? high-priority-blockages severity)))
        )
        (map-set high-priority-blockages severity 
          (unwrap! (as-max-len? (append high-priority-list blockage-id) u100) ERR_INVALID_STATUS))
      )
      true
    )
    
    ;; Create emergency alert if severity is at threshold
    (if (>= severity (var-get emergency-threshold))
      (begin
        (unwrap! (create-emergency-alert blockage-id "flood-risk" severity "High-risk blockage detected") ERR_INVALID_STATUS)
        true
      )
      true
    )
    
    ;; Increment counter
    (var-set next-blockage-id (+ blockage-id u1))
    
    (ok blockage-id)
  )
)

;; Public function: Verify blockage report
(define-public (verify-blockage (blockage-id uint) (verified bool) (estimated-clearing-time (optional uint)))
  (let 
    (
      (blockage-data (unwrap! (map-get? blockage-reports blockage-id) ERR_BLOCKAGE_NOT_FOUND))
    )
    ;; Check authorization
    (asserts! (or 
      (is-eq tx-sender (var-get contract-owner))
      (default-to false (map-get? authorized-crews tx-sender))
    ) ERR_NOT_AUTHORIZED)
    
    ;; Update blockage status
    (map-set blockage-reports blockage-id (merge blockage-data {
      status: (if verified "verified" "false-alarm"),
      verification-timestamp: (some stacks-block-height),
      verified-by: (some tx-sender),
      estimated-clearing-time: estimated-clearing-time
    }))
    
    (ok true)
  )
)

;; Public function: Assign clearing crew
(define-public (assign-clearing-crew
  (blockage-id uint)
  (assigned-crew (string-ascii 200))
  (estimated-completion uint)
  (equipment-used (string-ascii 500))
  (clearing-method (string-ascii 200)))
  (let 
    (
      (clearing-id (var-get next-clearing-id))
      (blockage-data (unwrap! (map-get? blockage-reports blockage-id) ERR_BLOCKAGE_NOT_FOUND))
    )
    ;; Check authorization
    (asserts! (or 
      (is-eq tx-sender (var-get contract-owner))
      (default-to false (map-get? authorized-crews tx-sender))
    ) ERR_NOT_AUTHORIZED)
    
    ;; Create clearing activity
    (map-set clearing-activities clearing-id {
      blockage-id: blockage-id,
      assigned-crew: assigned-crew,
      start-time: stacks-block-height,
      estimated-completion: estimated-completion,
      actual-completion: none,
      equipment-used: equipment-used,
      clearing-method: clearing-method,
      status: "assigned",
      notes: "",
      created-by: tx-sender,
      completed-by: none
    })
    
    ;; Update blockage status
    (map-set blockage-reports blockage-id (merge blockage-data {status: "clearing"}))
    
    ;; Increment counter
    (var-set next-clearing-id (+ clearing-id u1))
    
    (ok clearing-id)
  )
)

;; Public function: Update clearing progress
(define-public (update-clearing-progress (clearing-id uint) (new-status (string-ascii 20)) (notes (string-ascii 1000)))
  (let 
    (
      (clearing-data (unwrap! (map-get? clearing-activities clearing-id) ERR_CLEARING_NOT_FOUND))
      (blockage-id (get blockage-id clearing-data))
      (blockage-data (unwrap! (map-get? blockage-reports blockage-id) ERR_BLOCKAGE_NOT_FOUND))
    )
    ;; Check authorization
    (asserts! (or 
      (is-eq tx-sender (var-get contract-owner))
      (is-eq tx-sender (get created-by clearing-data))
      (default-to false (map-get? authorized-crews tx-sender))
    ) ERR_NOT_AUTHORIZED)
    
    ;; Validate status
    (asserts! (or 
      (is-eq new-status "in-progress")
      (is-eq new-status "completed")
      (is-eq new-status "cancelled")
    ) ERR_INVALID_STATUS)
    
    ;; Update clearing activity
    (map-set clearing-activities clearing-id (merge clearing-data {
      status: new-status,
      notes: notes,
      actual-completion: (if (is-eq new-status "completed") (some stacks-block-height) none),
      completed-by: (if (is-eq new-status "completed") (some tx-sender) none)
    }))
    
    ;; Update blockage status if completed
    (if (is-eq new-status "completed")
      (map-set blockage-reports blockage-id (merge blockage-data {status: "cleared"}))
      true
    )
    
    (ok true)
  )
)

;; Public function: Create emergency alert
(define-public (create-emergency-alert
  (blockage-id uint)
  (alert-type (string-ascii 50))
  (priority uint)
  (affected-area (string-ascii 500)))
  (let 
    (
      (alert-id (var-get next-alert-id))
    )
    ;; Check authorization
    (asserts! (or 
      (is-eq tx-sender (var-get contract-owner))
      (default-to false (map-get? authorized-crews tx-sender))
    ) ERR_NOT_AUTHORIZED)
    
    ;; Validate priority
    (asserts! (and (>= priority u1) (<= priority u5)) ERR_INVALID_SEVERITY)
    
    ;; Create alert
    (map-set emergency-alerts alert-id {
      blockage-id: blockage-id,
      alert-type: alert-type,
      priority: priority,
      affected-area: affected-area,
      response-required: (>= priority u3),
      alert-timestamp: stacks-block-height,
      resolved-timestamp: none,
      status: "active",
      response-team: none,
      resolution-notes: none
    })
    
    ;; Increment counter
    (var-set next-alert-id (+ alert-id u1))
    
    (ok alert-id)
  )
)

;; Public function: Resolve emergency alert
(define-public (resolve-emergency-alert (alert-id uint) (resolution-notes (string-ascii 1000)))
  (let 
    (
      (alert-data (unwrap! (map-get? emergency-alerts alert-id) ERR_ALERT_NOT_FOUND))
    )
    ;; Check authorization
    (asserts! (or 
      (is-eq tx-sender (var-get contract-owner))
      (default-to false (map-get? authorized-crews tx-sender))
    ) ERR_NOT_AUTHORIZED)
    
    ;; Update alert
    (map-set emergency-alerts alert-id (merge alert-data {
      resolved-timestamp: (some stacks-block-height),
      status: "resolved",
      resolution-notes: (some resolution-notes)
    }))
    
    (ok true)
  )
)

;; Public function: Add authorized reporter
(define-public (add-authorized-reporter (reporter principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (map-set authorized-reporters reporter true)
    (ok true)
  )
)

;; Public function: Add authorized crew
(define-public (add-authorized-crew (crew principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (map-set authorized-crews crew true)
    (ok true)
  )
)

;; Read-only function: Get blockage details
(define-read-only (get-blockage (blockage-id uint))
  (map-get? blockage-reports blockage-id)
)

;; Read-only function: Get clearing activity details
(define-read-only (get-clearing-activity (clearing-id uint))
  (map-get? clearing-activities clearing-id)
)

;; Read-only function: Get emergency alert details
(define-read-only (get-emergency-alert (alert-id uint))
  (map-get? emergency-alerts alert-id)
)

;; Read-only function: Get blockages by location
(define-read-only (get-blockages-by-location (location-x uint) (location-y uint))
  (map-get? location-blockages {x: location-x, y: location-y})
)

;; Read-only function: Get high priority blockages by severity
(define-read-only (get-high-priority-blockages (severity uint))
  (map-get? high-priority-blockages severity)
)

;; Read-only function: Check if reporter is authorized
(define-read-only (is-authorized-reporter (reporter principal))
  (default-to false (map-get? authorized-reporters reporter))
)

;; Read-only function: Check if crew is authorized
(define-read-only (is-authorized-crew (crew principal))
  (default-to false (map-get? authorized-crews crew))
)

;; Read-only function: Get contract owner
(define-read-only (get-contract-owner)
  (var-get contract-owner)
)

;; Read-only function: Get emergency threshold
(define-read-only (get-emergency-threshold)
  (var-get emergency-threshold)
)

;; Read-only function: Get next blockage ID
(define-read-only (get-next-blockage-id)
  (var-get next-blockage-id)
)

;; Read-only function: Get next clearing ID
(define-read-only (get-next-clearing-id)
  (var-get next-clearing-id)
)

;; Read-only function: Get next alert ID
(define-read-only (get-next-alert-id)
  (var-get next-alert-id)
)

