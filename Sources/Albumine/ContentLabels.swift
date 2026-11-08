import Foundation

/// Noms français des catégories reconnues par Vision (VNClassifyImageRequest).
/// Les catégories absentes de cette table restent cherchables par leur nom anglais.
enum ContentLabels {
    static func french(_ id: String) -> String {
        names[id] ?? id.replacingOccurrences(of: "_", with: " ")
    }

    /// Texte normalisé dans lequel la recherche s'effectue (français + anglais + synonymes).
    static func searchText(_ id: String) -> String {
        cache.withLock { cache in
            if let s = cache[id] { return s }
            let s = ([french(id), id.replacingOccurrences(of: "_", with: " ")] + (synonyms[id] ?? []))
                .joined(separator: " ").searchFolded
            cache[id] = s
            return s
        }
    }

    private static let cache = Mutex<[String: String]>([:])

    /// Catégories trop générales pour être utiles (ni affichées ni cherchées).
    static let ignored: Set<String> = [
        "structure", "material", "land", "liquid", "conveyance", "consumer_electronics", "container",
        "housewares", "textile", "wood_processed", "raw_glass", "light", "daytime", "outdoor", "art",
        "machine", "tool", "media", "games", "recreation", "decoration", "cord", "rim", "frame", "sign",
    ]

    static let synonyms: [String: [String]] = [
        "beach": ["mer", "vacances", "sable"], "ocean": ["mer"], "shore": ["mer", "côte", "littoral"],
        "snow": ["hiver", "ski"], "skiing": ["neige", "montagne"], "mountain": ["montagnes"],
        "birthday_cake": ["anniversaire"], "celebration": ["fête"], "wedding": ["noces"],
        "christmas_tree": ["noël"], "christmas_decoration": ["noël"], "santa_claus": ["noël"],
        "people": ["gens", "personnes", "groupe"], "crowd": ["gens", "groupe"],
        "baby": ["enfant"], "child": ["enfants", "gamin"], "teen": ["ado"],
        "dog": ["chiens", "toutou"], "cat": ["chats", "minou"], "canine": ["chien"], "feline": ["chat"],
        "sunset_sunrise": ["soleil", "crépuscule", "aube"], "night_sky": ["nuit", "étoiles"],
        "food": ["repas", "manger", "plat"], "restaurant": ["repas", "dîner"],
        "screenshot": ["capture"], "document": ["papier", "scan"],
    ]

    static let names: [String: String] = [
        // Personnes et événements
        "people": "personnes", "adult": "adulte", "baby": "bébé", "child": "enfant", "teen": "adolescent",
        "crowd": "foule", "bride": "mariée", "groom": "marié", "bridesmaid": "demoiselle d'honneur",
        "wedding": "mariage", "wedding_cake": "gâteau de mariage", "wedding_dress": "robe de mariée",
        "ceremony": "cérémonie", "celebration": "fête", "birthday_cake": "gâteau d'anniversaire",
        "graduation": "remise de diplôme", "party": "fête", "parade": "défilé", "carnival": "carnaval",
        "costume": "déguisement", "christmas_tree": "sapin de Noël", "christmas_decoration": "décoration de Noël",
        "santa_claus": "Père Noël", "easter_egg": "œuf de Pâques", "jack_o_lantern": "citrouille d'Halloween",
        "gift": "cadeau", "balloon": "ballon de baudruche", "candle": "bougie", "fireworks": "feu d'artifice",
        "sparkler": "cierge magique", "concert": "concert", "dancing": "danse", "singer": "chanteur",
        "performance": "spectacle", "theater": "théâtre", "circus": "cirque", "clown": "clown",
        "selfie": "selfie", "portrait": "portrait", "toy": "jouet", "doll": "poupée",
        "stuffed_animals": "peluche", "playground": "aire de jeux", "swing_playground": "balançoire",
        "slide_toy": "toboggan", "seesaw": "tape-cul", "trampoline": "trampoline", "sandcastle": "château de sable",
        "classroom": "salle de classe", "conference": "conférence", "ballet": "ballet", "ballet_dancer": "danseuse",
        "military_uniform": "uniforme militaire", "suit": "costume", "tuxedo": "smoking", "gown": "robe de soirée",

        // Animaux
        "animal": "animal", "dog": "chien", "cat": "chat", "puppy": "chiot", "kitten": "chaton",
        "adult_cat": "chat", "canine": "chien", "feline": "félin", "horse": "cheval", "pony": "poney",
        "donkey": "âne", "cow": "vache", "pig": "cochon", "sheep": "mouton", "goat": "chèvre",
        "rabbit": "lapin", "hamster": "hamster", "guinea_pig": "cochon d'Inde", "bird": "oiseau",
        "duck": "canard", "swan": "cygne", "gull": "mouette", "pigeon": "pigeon", "chicken": "poule",
        "poultry": "volaille", "parrot": "perroquet", "owl": "hibou", "eagle": "aigle", "fish": "poisson",
        "goldfish": "poisson rouge", "dolphin": "dauphin", "whale": "baleine", "shark": "requin",
        "seal": "phoque", "penguin": "manchot", "turtle": "tortue", "tortoise": "tortue", "frog": "grenouille",
        "snake": "serpent", "lizard": "lézard", "insect": "insecte", "butterfly": "papillon", "bee": "abeille",
        "ladybug": "coccinelle", "spider": "araignée", "snail": "escargot", "elephant": "éléphant",
        "giraffe": "girafe", "lion": "lion", "tiger": "tigre", "zebra": "zèbre", "monkey": "singe",
        "bear": "ours", "deer": "cerf", "fox": "renard", "squirrel": "écureuil", "camel": "chameau",
        "kangaroo": "kangourou", "koala": "koala", "panda": "panda", "flamingo": "flamant rose",
        "jellyfish": "méduse", "crab": "crabe", "starfish": "étoile de mer", "seashell": "coquillage",
        "zoo": "zoo", "aquarium": "aquarium", "farm": "ferme", "equestrian": "équitation", "mammal": "mammifère",
        "reptile": "reptile", "rodent": "rongeur", "ungulates": "ongulé", "cetacean": "cétacé",
        "german_shepherd": "berger allemand", "retriever": "retriever", "labrador": "labrador",
        "poodle": "caniche", "bulldog": "bouledogue", "dachshund": "teckel", "chihuahua": "chihuahua",
        "beagle": "beagle", "terrier": "terrier", "spaniel": "épagneul", "husky": "husky",

        // Nature et paysages
        "beach": "plage", "ocean": "océan", "sea": "mer", "shore": "rivage", "sand": "sable",
        "sand_dune": "dune", "island": "île", "coral_reef": "récif de corail", "underwater": "sous l'eau",
        "water": "eau", "water_body": "plan d'eau", "lake": "lac", "river": "rivière", "creek": "ruisseau",
        "waterfall": "cascade", "waterways": "canal", "wetland": "marais", "mountain": "montagne",
        "hill": "colline", "cliff": "falaise", "canyon": "canyon", "rocks": "rochers", "cave": "grotte",
        "volcano": "volcan", "glacier": "glacier", "iceberg": "iceberg", "desert": "désert",
        "forest": "forêt", "jungle": "jungle", "tree": "arbre", "palm_tree": "palmier", "oak_tree": "chêne",
        "maple_tree": "érable", "evergreen": "conifère", "sequoia": "séquoia", "willow": "saule",
        "foliage": "feuillage", "vegetation": "végétation", "grass": "herbe", "plant": "plante",
        "flower": "fleur", "blossom": "fleurs (arbre)", "rose": "rose", "tulip": "tulipe",
        "sunflower": "tournesol", "daisy": "marguerite", "orchid": "orchidée", "lily": "lys",
        "dandelion": "pissenlit", "bouquet": "bouquet", "flower_arrangement": "composition florale",
        "garden": "jardin", "park": "parc", "orchard": "verger", "vineyard": "vigne", "rice_field": "rizière",
        "agriculture": "agriculture", "wheat": "blé", "mushroom": "champignon", "moss": "mousse",
        "sky": "ciel", "blue_sky": "ciel bleu", "cloudy": "nuageux", "sun": "soleil",
        "sunset_sunrise": "coucher de soleil", "night_sky": "ciel nocturne", "moon": "lune",
        "aurora": "aurore boréale", "rainbow": "arc-en-ciel", "storm": "orage", "thunderstorm": "orage",
        "lightning": "éclair", "fog": "brouillard", "haze": "brume", "snow": "neige", "blizzard": "tempête de neige",
        "ice": "glace", "frozen": "gel", "fire": "feu", "flame": "flamme", "embers": "braises",
        "celestial_body": "astre", "wood_natural": "bois", "branch": "branche", "nest": "nid",

        // Lieux et bâtiments
        "cityscape": "ville", "street": "rue", "alley": "ruelle", "road": "route", "dirt_road": "chemin",
        "path": "sentier", "trail": "sentier", "sidewalk": "trottoir", "crosswalk": "passage piéton",
        "bridge": "pont", "tunnel": "tunnel", "building": "bâtiment", "skyscraper": "gratte-ciel",
        "house_single": "maison", "domicile": "maison", "apartment": "appartement", "castle": "château",
        "church": "église", "belltower": "clocher", "tower": "tour", "clock_tower": "tour de l'horloge",
        "lighthouse": "phare", "monument": "monument", "statue": "statue", "fountain": "fontaine",
        "ruins": "ruines", "pyramid": "pyramide", "museum": "musée", "library": "bibliothèque",
        "stadium": "stade", "arena": "arène", "harbour": "port", "dock": "quai", "pier": "jetée",
        "marina": "marina", "airport": "aéroport", "train_station": "gare", "parking_lot": "parking",
        "storefront": "vitrine", "interior_shop": "magasin", "restaurant": "restaurant", "bar": "bar",
        "nightclub": "boîte de nuit", "hospital": "hôpital", "amusement_park": "parc d'attractions",
        "rollercoaster": "montagnes russes", "ferris_wheel": "grande roue", "carousel": "manège",
        "fairground": "fête foraine", "barn": "grange", "windmill": "moulin à vent", "watermill": "moulin à eau",
        "dam": "barrage", "greenhouse": "serre", "tent": "tente", "camping": "camping", "igloo": "igloo",
        "roof": "toit", "chimney": "cheminée", "window": "fenêtre", "door": "porte", "stairs": "escalier",
        "balcony": "balcon", "patio": "terrasse", "porch": "porche", "deck": "terrasse en bois",
        "pool": "piscine", "jacuzzi": "jacuzzi", "garage": "garage", "fence": "clôture", "gazebo": "kiosque",
        "arch": "arche", "dome": "dôme", "stained_glass": "vitrail", "graffiti": "graffiti",

        // Intérieur et objets
        "interior_room": "intérieur", "living_room": "salon", "bedroom": "chambre", "kitchen": "cuisine",
        "kitchen_room": "cuisine", "dining_room": "salle à manger", "bathroom": "salle de bain",
        "bathroom_room": "salle de bain", "office_supplies": "fournitures de bureau", "desk": "bureau",
        "table": "table", "chair": "chaise", "sofa": "canapé", "bed": "lit", "crib": "lit de bébé",
        "high_chair": "chaise haute", "stroller": "poussette", "fireplace": "cheminée", "lamp": "lampe",
        "chandelier": "lustre", "curtain": "rideau", "bookshelf": "bibliothèque", "book": "livre",
        "newspaper": "journal", "magazine": "magazine", "painting": "tableau", "television": "télévision",
        "computer": "ordinateur", "laptop": "ordinateur portable", "phone": "téléphone", "camera": "appareil photo",
        "headphones": "casque audio", "clock": "horloge", "watch": "montre", "eyeglasses": "lunettes",
        "sunglasses": "lunettes de soleil", "hat": "chapeau", "sunhat": "chapeau de soleil", "helmet": "casque",
        "backpack": "sac à dos", "bag": "sac", "suitcase": "valise", "luggage": "bagages",
        "umbrella": "parapluie", "jewelry": "bijoux", "shoes": "chaussures", "footwear": "chaussures",
        "clothing": "vêtements", "jacket": "veste", "jeans": "jean", "swimsuit": "maillot de bain",
        "scarf": "écharpe", "glove": "gant", "vase": "vase", "mug": "tasse", "cup": "tasse",
        "plate": "assiette", "bowl": "bol", "bottle": "bouteille", "drinking_glass": "verre",
        "tableware": "vaisselle", "utensil": "ustensile", "money": "argent", "currency": "billets",
        "map": "carte", "flag": "drapeau", "musical_instrument": "instrument de musique", "guitar": "guitare",
        "piano": "piano", "violin": "violon", "drum": "batterie", "trumpet": "trompette", "music": "musique",
        "microphone": "micro", "board_game": "jeu de société", "chess": "échecs", "puzzles": "puzzle",
        "play_card": "cartes à jouer", "videogame": "jeu vidéo", "kite": "cerf-volant", "ball": "ballon",

        // Nourriture et boissons
        "food": "nourriture", "meal": "repas", "dessert": "dessert", "cake": "gâteau", "cake_regular": "gâteau",
        "cupcake": "cupcake", "pie": "tarte", "pastry": "pâtisserie", "baked_goods": "viennoiseries",
        "bread": "pain", "croissant": "croissant", "cookie": "biscuit", "chocolate": "chocolat",
        "candy": "bonbons", "ice_cream": "glace", "frozen_dessert": "dessert glacé", "pancake": "crêpe",
        "crepe": "crêpe", "waffle": "gaufre", "cheese": "fromage", "fondue": "fondue", "egg": "œuf",
        "omelet": "omelette", "salad": "salade", "soup": "soupe", "pasta": "pâtes", "spaghetti": "spaghetti",
        "pizza": "pizza", "hamburger": "hamburger", "sandwich": "sandwich", "fries": "frites",
        "meat": "viande", "steak": "steak", "sausage": "saucisse", "ham": "jambon", "seafood": "fruits de mer",
        "oyster": "huîtres", "mussel": "moules", "lobster": "homard", "sushi": "sushi", "paella": "paella",
        "barbecue": "barbecue", "grill": "barbecue", "fruit": "fruit", "apple": "pomme", "banana": "banane",
        "oranges": "orange", "lemon": "citron", "strawberry": "fraise", "cherry": "cerise", "grape": "raisin",
        "watermelon": "pastèque", "melon": "melon", "peach": "pêche", "pear": "poire", "berry": "baies",
        "vegetable": "légume", "tomato": "tomate", "potato": "pomme de terre", "carrot": "carotte",
        "corn": "maïs", "pumpkin": "citrouille", "drink": "boisson", "coffee": "café", "tea_drink": "thé",
        "juice": "jus", "beer": "bière", "wine": "vin", "red_wine": "vin rouge", "white_wine": "vin blanc",
        "sparkling_wine": "champagne", "wine_bottle": "bouteille de vin", "cocktail": "cocktail",
        "picnic": "pique-nique",

        // Sports et loisirs
        "sport": "sport", "skiing": "ski", "ski_equipment": "matériel de ski", "snowboarding": "snowboard",
        "snowboard": "snowboard", "sledding": "luge", "sled": "luge", "snowman": "bonhomme de neige",
        "ice_skating": "patinage", "chairlift": "télésiège", "cableway": "téléphérique",
        "winter_sport": "sport d'hiver", "swimming": "natation", "diving": "plongée", "scuba": "plongée",
        "snorkeling": "masque et tuba", "surfing": "surf", "surfboard": "planche de surf",
        "windsurfing": "planche à voile", "kayak": "kayak", "canoe": "canoë", "rafting": "rafting",
        "sailboat": "voilier", "boat": "bateau", "yacht": "yacht", "watercraft": "embarcation",
        "cruise_ship": "paquebot", "fishing": "pêche", "hiking": "randonnée", "rock_climbing": "escalade",
        "cycling": "vélo", "bicycle": "vélo", "tricycle": "tricycle", "scooter": "trottinette",
        "skateboard": "skate", "rollerskating": "roller", "soccer": "football", "football": "football américain",
        "rugby": "rugby", "tennis": "tennis", "basketball": "basket", "volleyball": "volley",
        "golf": "golf", "horse_riding": "équitation", "running": "course", "athletics": "athlétisme",
        "gymnastics": "gymnastique", "yoga": "yoga", "martial_arts": "arts martiaux", "boxing": "boxe",
        "bowling": "bowling", "billiards": "billard", "ping_pong": "ping-pong", "paragliding": "parapente",
        "parachute": "parachute", "hangglider": "deltaplane", "motorsport": "sport automobile",

        // Véhicules et transports
        "vehicle": "véhicule", "car": "voiture", "automobile": "voiture", "sportscar": "voiture de sport",
        "convertible": "cabriolet", "suv": "4x4", "jeep": "jeep", "van": "camionnette", "truck": "camion",
        "bus": "bus", "motorcycle": "moto", "tractor": "tracteur", "train": "train", "train_real": "train",
        "tramway": "tramway", "streetcar": "tramway", "airplane": "avion", "aircraft": "avion",
        "helicopter": "hélicoptère", "balloon_hotair": "montgolfière", "motorhome": "camping-car",
        "firetruck": "camion de pompiers", "police_car": "voiture de police", "ambulance": "ambulance",
        "railroad": "voie ferrée",

        // Documents et captures
        "screenshot": "capture d'écran", "document": "document", "printed_page": "page imprimée",
        "handwriting": "écriture manuscrite", "receipt": "ticket de caisse", "diagram": "schéma",
        "chart": "graphique", "illustrations": "illustration", "whiteboard": "tableau blanc",
        "passport": "passeport", "ticket": "billet", "credit_card": "carte bancaire", "envelope": "enveloppe",
        "calendar": "calendrier", "license_plate": "plaque d'immatriculation",
        "furniture": "meubles", "portal": "portail", "headgear": "couvre-chef", "pyrotechnics": "pyrotechnie",
        "chair_other": "chaise", "road_other": "route", "candy_other": "bonbons", "glove_other": "gant",
    ]
}

/// Petit verrou générique (cache partagé entre fils d'analyse).
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
