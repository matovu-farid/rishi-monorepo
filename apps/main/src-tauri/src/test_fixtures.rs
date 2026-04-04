// Test fixtures for embedding and vector search tests

pub struct TestChunk {
    pub text: &'static str,
    pub id: i64,
    pub query: &'static str,
}

const QUANTUM_COMPUTING_PARAGRAPH: &str = "Quantum computing represents a revolutionary approach to computation that leverages the principles of quantum mechanics to process information in fundamentally different ways than classical computers. Unlike traditional bits that exist in either a zero or one state, quantum bits or qubits can exist in a superposition of both states simultaneously. This property allows quantum computers to perform certain calculations exponentially faster than their classical counterparts. Researchers are exploring applications in cryptography, drug discovery, financial modeling, and optimization problems. Major technology companies and research institutions are investing heavily in developing practical quantum computing systems, though significant challenges remain in maintaining quantum coherence and reducing error rates.";

const ANCIENT_EGYPTIAN_PYRAMIDS_PARAGRAPH: &str = "The ancient Egyptian pyramids stand as one of the most remarkable architectural achievements in human history, constructed over four thousand years ago as monumental tombs for pharaohs and their consorts. The Great Pyramid of Giza, built for Pharaoh Khufu around 2580 BCE, remains the largest and most famous of these structures, originally standing at 146.6 meters tall. These massive stone structures were built using sophisticated engineering techniques that remain impressive even by modern standards. The precise alignment with celestial bodies, the intricate internal passageways, and the sheer scale of construction required thousands of workers and decades of labor. The pyramids continue to fascinate archaeologists, historians, and tourists alike, representing the pinnacle of ancient Egyptian civilization and their beliefs about the afterlife.";

const CLIMATE_RENEWABLE_ENERGY_PARAGRAPH: &str = "Climate change represents one of the most pressing challenges facing humanity in the 21st century, driven primarily by greenhouse gas emissions from human activities. The transition to renewable energy sources such as solar, wind, hydroelectric, and geothermal power has become essential for reducing carbon emissions and mitigating global warming. Solar panels and wind turbines have seen dramatic cost reductions over the past decade, making renewable energy increasingly competitive with fossil fuels. Many countries have set ambitious targets to achieve carbon neutrality by mid-century, requiring massive investments in renewable energy infrastructure and energy storage systems. This transition also creates new economic opportunities in green technology sectors while addressing environmental concerns and improving energy security.";

const SPACE_EXPLORATION_MARS_PARAGRAPH: &str = "Space exploration has entered an exciting new era with multiple missions targeting Mars as humanity's next frontier. NASA's Perseverance rover continues to search for signs of ancient microbial life while collecting rock samples for future return to Earth. Private companies like SpaceX are developing reusable rocket technology and planning crewed missions to Mars within the next decade. The Red Planet presents numerous challenges including extreme temperatures, thin atmosphere, radiation exposure, and the need for sustainable life support systems. Scientists are studying Mars' geology, climate history, and potential for terraforming to understand whether it could support human colonization. These missions advance our understanding of planetary science and test technologies that could enable long-term human presence beyond Earth.";

const MACHINE_LEARNING_NEURAL_NETWORKS_PARAGRAPH: &str = "Machine learning and neural networks have transformed numerous industries by enabling computers to learn patterns from data without explicit programming. Deep learning, a subset of machine learning using artificial neural networks with multiple layers, has achieved remarkable success in image recognition, natural language processing, and game playing. These systems learn by processing vast amounts of training data, adjusting millions of parameters through backpropagation algorithms. Convolutional neural networks excel at visual tasks while transformer architectures have revolutionized language understanding and generation. The field continues to evolve rapidly with new architectures, training techniques, and applications emerging regularly. However, challenges remain including interpretability, data requirements, computational costs, and ethical considerations around bias and privacy.";

pub fn get_test_chunks() -> Vec<TestChunk> {
    vec![
        TestChunk {
            text: QUANTUM_COMPUTING_PARAGRAPH,
            id: 1,
            query: "How do quantum computers use superposition to solve problems faster than classical computers?",
        },
        TestChunk {
            text: ANCIENT_EGYPTIAN_PYRAMIDS_PARAGRAPH,
            id: 2,
            query: "What techniques did ancient Egyptians use to construct the massive stone tombs for pharaohs?",
        },
        TestChunk {
            text: CLIMATE_RENEWABLE_ENERGY_PARAGRAPH,
            id: 3,
            query: "What renewable energy technologies are helping reduce greenhouse gas emissions and combat global warming?",
        },
        TestChunk {
            text: SPACE_EXPLORATION_MARS_PARAGRAPH,
            id: 4,
            query: "What are the main challenges and goals of current missions exploring the Red Planet?",
        },
        TestChunk {
            text: MACHINE_LEARNING_NEURAL_NETWORKS_PARAGRAPH,
            id: 5,
            query: "How do deep neural networks learn to recognize patterns and process information from large datasets?",
        },
    ]
}
